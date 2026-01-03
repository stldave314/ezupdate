#!/bin/bash

# ezupdate.sh
# A multi-manager system update utility with rollback and logging.
#
# Usage: ./ezupdate.sh [options]

# Default Configuration
LOG_DIR="/var/log/ezupdate"
HISTORY_LOG="$LOG_DIR/history.csv"
RUN_LOG="$LOG_DIR/ezupdate_run.log"
REPORT_FILE="$LOG_DIR/ezupdate_report.txt"
EMAIL_ADDR=""
ROLLBACK_MODE=false
ROLLBACK_FILE=""
NON_INTERACTIVE=true # Always non-interactive selection now
REBOOT_REQUIRED=false

TEMP_DIR=$(mktemp -d)

# cleanup on exit
trap "rm -rf $TEMP_DIR" EXIT

# --- Logging & Helper Functions ---

init_logs() {
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR" 2>/dev/null
        if [ $? -ne 0 ]; then
            LOG_DIR="$HOME/.ezupdate/logs"
            HISTORY_LOG="$LOG_DIR/history.csv"
            RUN_LOG="$LOG_DIR/ezupdate_run.log"
            REPORT_FILE="$LOG_DIR/ezupdate_report.txt"
            mkdir -p "$LOG_DIR"
            echo "Warning: Could not write to /var/log. Using $LOG_DIR"
        fi
    fi
    touch "$HISTORY_LOG" "$RUN_LOG" "$REPORT_FILE"
}

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$RUN_LOG"
}

record_transaction() {
    echo "$1|$2|$3|$4|$5|$6|$7" >> "$HISTORY_LOG"
}

show_help() {
    echo "EzUpdate - System Update Wrapper v2.1"
    echo ""
    echo "Usage: sudo ./ezupdate.sh [options]"
    echo ""
    echo "Options:"
    echo "  -h, --help           Show this help message."
    echo "  --log-dir <path>     Specify custom log directory."
    echo "  --rollback <file>    Rollback changes based on a history file (or 'latest' for last run)."
    echo "  --email <address>    Email the report to this address after completion."
    echo ""
}

# --- Argument Parsing ---

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        --log-dir)
            LOG_DIR="$2"
            HISTORY_LOG="$LOG_DIR/history.csv"
            RUN_LOG="$LOG_DIR/ezupdate_run.log"
            REPORT_FILE="$LOG_DIR/ezupdate_report.txt"
            shift 2
            ;;
        --rollback)
            ROLLBACK_MODE=true
            ROLLBACK_FILE="$2"
            shift 2
            ;;
        --email)
            EMAIL_ADDR="$2"
            shift 2
            ;;
        -y|--yes)
            # Kept for compatibility, but selection is now always off
            shift
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

init_logs

# --- Rollback Logic ---

perform_rollback() {
    log "Starting Rollback Process..."
    local target_file="$ROLLBACK_FILE"
    if [[ "$ROLLBACK_FILE" == "latest" ]]; then target_file="$HISTORY_LOG"; fi
    if [ ! -f "$target_file" ]; then log "Error: Rollback file not found."; exit 1; fi
    if ! command -v tac &> /dev/null; then log "Error: 'tac' missing."; exit 1; fi

    tac "$target_file" | while IFS='|' read -r TIMESTAMP BATCH_ID MANAGER PACKAGE ACTION OLD_VAL NEW_VAL; do
        if [[ -z "$PACKAGE" || -z "$MANAGER" ]]; then continue; fi
        log "Reverting $MANAGER: $PACKAGE..."
        case $MANAGER in
            APT)
                if [[ "$OLD_VAL" == "NONE" ]]; then
                    sudo apt-get remove -y "$PACKAGE" >> "$RUN_LOG" 2>&1
                else
                    sudo apt-get install -y --allow-downgrades "$PACKAGE=$OLD_VAL" >> "$RUN_LOG" 2>&1
                fi
                ;;
            FLATPAK)
                flatpak update -y --commit="$OLD_VAL" "$PACKAGE" >> "$RUN_LOG" 2>&1
                ;;
            SNAP)
                sudo snap revert "$PACKAGE" >> "$RUN_LOG" 2>&1
                ;;
            DNF)
                if [[ "$PACKAGE" == "BULK_TRANSACTION" ]]; then
                    sudo dnf history undo -y "$OLD_VAL" >> "$RUN_LOG" 2>&1
                fi
                ;;
        esac
    done
    log "Rollback complete."
}

if $ROLLBACK_MODE; then
    perform_rollback
    exit 0
fi

# --- Main Logic ---

MANAGERS=()
detect_managers() {
    log "Detecting package managers..."
    if command -v apt-get &> /dev/null; then MANAGERS+=("apt"); fi
    if command -v dnf &> /dev/null; then MANAGERS+=("dnf"); fi
    if command -v flatpak &> /dev/null; then MANAGERS+=("flatpak"); fi
    if command -v snap &> /dev/null; then MANAGERS+=("snap"); fi
}

BATCH_ID="BATCH_$(date +%s)"

perform_updates() {
    echo "Update Report - $(date)" > "$REPORT_FILE"
    
    for mgr in "${MANAGERS[@]}"; do
        log "Processing $mgr updates..."
        
        case $mgr in
            apt)
                echo "[$mgr] Pending Updates:" >> "$REPORT_FILE"
                apt list --upgradable 2>/dev/null | grep -v "Listing..." >> "$REPORT_FILE"
                
                sudo apt-get update -y >> "$RUN_LOG" 2>&1
                
                # Execution
                sudo DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y > "$TEMP_DIR/apt_out" 2>&1
                cat "$TEMP_DIR/apt_out" >> "$RUN_LOG"
                
                echo "[$mgr] Applied Updates:" >> "$REPORT_FILE"
                grep -E "^(Inst|Setting up)" "$TEMP_DIR/apt_out" >> "$REPORT_FILE"
                echo "--------------------------------" >> "$REPORT_FILE"
                
                # History Recording
                grep "^Inst" "$TEMP_DIR/apt_out" | while read -r line; do
                    pkg=$(echo "$line" | cut -d' ' -f2)
                    ver=$(echo "$line" | cut -d'(' -f2 | cut -d')' -f1)
                    record_transaction "$(date -Iseconds)" "$BATCH_ID" "APT" "$pkg" "UPDATE" "OLD" "$ver"
                done
                ;;
            dnf)
                echo "[$mgr] Pending Updates:" >> "$REPORT_FILE"
                dnf check-update >> "$REPORT_FILE" 2>/dev/null
                
                sudo dnf upgrade -y > "$TEMP_DIR/dnf_out" 2>&1
                cat "$TEMP_DIR/dnf_out" >> "$RUN_LOG"
                
                echo "[$mgr] Applied Updates:" >> "$REPORT_FILE"
                grep -E "^(Upgrading|Installing):" "$TEMP_DIR/dnf_out" -A 1000 >> "$REPORT_FILE"
                echo "--------------------------------" >> "$REPORT_FILE"
                
                new_id=$(sudo dnf history | head -n 3 | tail -n 1 | awk '{print $1}')
                record_transaction "$(date -Iseconds)" "$BATCH_ID" "DNF" "BULK_TRANSACTION" "UPDATE" "$new_id" "N/A"
                ;;
            flatpak)
                echo "[$mgr] Pending Updates:" >> "$REPORT_FILE"
                flatpak update --system --dry-run 2>>"$RUN_LOG" >> "$REPORT_FILE"
                if [ -n "$SUDO_USER" ]; then
                     echo "--- User Flatpaks ($SUDO_USER) ---" >> "$REPORT_FILE"
                     sudo -u "$SUDO_USER" flatpak update --user --dry-run 2>>"$RUN_LOG" >> "$REPORT_FILE"
                fi
                
                log "Updating System Flatpaks..."
                flatpak update -y > "$TEMP_DIR/flatpak_out" 2>&1
                cat "$TEMP_DIR/flatpak_out" >> "$RUN_LOG"
                
                echo "[$mgr] Applied Updates (System):" >> "$REPORT_FILE"
                if grep -q "Nothing to do" "$TEMP_DIR/flatpak_out"; then
                    echo "No updates." >> "$REPORT_FILE"
                else
                    grep -E "^ [0-9]+\." "$TEMP_DIR/flatpak_out" >> "$REPORT_FILE"
                fi
                
                if [ -n "$SUDO_USER" ]; then
                    log "Updating User Flatpaks ($SUDO_USER)..."
                    sudo -u "$SUDO_USER" flatpak update --user -y > "$TEMP_DIR/flatpak_user_out" 2>&1
                    cat "$TEMP_DIR/flatpak_user_out" >> "$RUN_LOG"
                    
                    echo "[$mgr] Applied Updates (User):" >> "$REPORT_FILE"
                    if grep -q "Nothing to do" "$TEMP_DIR/flatpak_user_out"; then
                        echo "No updates." >> "$REPORT_FILE"
                    else
                        grep -E "^ [0-9]+\." "$TEMP_DIR/flatpak_user_out" >> "$REPORT_FILE"
                    fi
                fi
                echo "--------------------------------" >> "$REPORT_FILE"
                ;;
            snap)
                echo "[$mgr] Pending Updates:" >> "$REPORT_FILE"
                snap refresh --list >> "$REPORT_FILE" 2>>"$RUN_LOG"
                
                sudo snap refresh > "$TEMP_DIR/snap_out" 2>&1
                cat "$TEMP_DIR/snap_out" >> "$RUN_LOG"
                
                echo "[$mgr] Applied Updates:" >> "$REPORT_FILE"
                grep "refreshed" "$TEMP_DIR/snap_out" >> "$REPORT_FILE"
                echo "--------------------------------" >> "$REPORT_FILE"
                ;;
        esac
    done
}

cleanup_system() {
    log "Cleaning up..."
    if [[ " ${MANAGERS[*]} " =~ " apt " ]]; then
        sudo apt-get autoremove -y >> "$RUN_LOG" 2>&1
        sudo apt-get clean >> "$RUN_LOG" 2>&1
    fi
    if [[ " ${MANAGERS[*]} " =~ " flatpak " ]]; then
        flatpak uninstall --unused -y >> "$RUN_LOG" 2>&1
    fi
    if [[ " ${MANAGERS[*]} " =~ " dnf " ]]; then
        sudo dnf autoremove -y >> "$RUN_LOG" 2>&1
    fi
}

check_reboot() {
    if [ -f /var/run/reboot-required ]; then
        REBOOT_REQUIRED=true
    elif command -v dnf &> /dev/null; then
        if sudo dnf needs-restarting -r &>/dev/null; then
             if [ $? -eq 1 ]; then REBOOT_REQUIRED=true; fi
        fi
    fi
    if $REBOOT_REQUIRED; then
        echo "*** REBOOT REQUIRED ***" >> "$REPORT_FILE"
    else
        echo "No reboot required." >> "$REPORT_FILE"
    fi
}

send_email() {
    if [ -n "$EMAIL_ADDR" ]; then
        log "Sending email to $EMAIL_ADDR..."
        (echo "Subject: EzUpdate Report - $(hostname)"; echo ""; cat "$REPORT_FILE") | (mail -t "$EMAIL_ADDR" 2>/dev/null || sendmail -t "$EMAIL_ADDR" 2>/dev/null || mutt -s "EzUpdate Report" -- "$EMAIL_ADDR" 2>/dev/null || log "Mail failed.")
    fi
}

# --- Execution ---
echo "Welcome to EzUpdate (Auto-mode)."
detect_managers
perform_updates
cleanup_system
check_reboot
send_email

echo "----------------------------------------"
cat "$REPORT_FILE"
echo "----------------------------------------"
echo "Logs: $LOG_DIR"
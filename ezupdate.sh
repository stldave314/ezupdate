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
NON_INTERACTIVE=false
REBOOT_REQUIRED=false

TEMP_DIR=$(mktemp -d)

# cleanup on exit
trap "rm -rf $TEMP_DIR" EXIT

# --- Logging & Helper Functions ---

# Ensure log directory exists (needs sudo usually)
init_logs() {
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR" 2>/dev/null
        if [ $? -ne 0 ]; then
            # Fallback to local if permission denied
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

# CSV Format: TIMESTAMP|BATCH_ID|MANAGER|PACKAGE|ACTION|OLD_VAL|NEW_VAL
record_transaction() {
    echo "$1|$2|$3|$4|$5|$6|$7" >> "$HISTORY_LOG"
}

show_help() {
    echo "EzUpdate - System Update Wrapper v2.0"
    echo ""
    echo "Usage: sudo ./ezupdate.sh [options]"
    echo ""
    echo "Options:"
    echo "  -h, --help           Show this help message."
    echo "  -y, --yes            Non-interactive mode (auto-accept updates)."
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
        -y|--yes)
            NON_INTERACTIVE=true
            shift
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
    
    if [[ "$ROLLBACK_FILE" == "latest" ]]; then
        target_file="$HISTORY_LOG"
        # In a real scenario, we might want to filter only the last batch ID
        # For this MVP, we parse the provided file.
    fi

    if [ ! -f "$target_file" ]; then
        log "Error: Rollback file '$target_file' not found."
        exit 1
    fi

    # Read file in reverse order to undo latest changes first
    # Using 'tac' to reverse lines
    if ! command -v tac &> /dev/null; then
        log "Error: 'tac' command not found. Cannot read log in reverse."
        exit 1
    fi

    tac "$target_file" | while IFS='|' read -r TIMESTAMP BATCH_ID MANAGER PACKAGE ACTION OLD_VAL NEW_VAL;
    do
        # Basic validation
        if [[ -z "$PACKAGE" || -z "$MANAGER" ]]; then continue; fi

        log "Reverting $MANAGER package: $PACKAGE to $OLD_VAL..."

        case $MANAGER in
            APT)
                # Attempt downgrade. 
                # Note: OLD_VAL should be version string.
                # If OLD_VAL is empty/none, it was a new install -> remove it.
                if [[ "$OLD_VAL" == "NONE" ]]; then
                    sudo apt-get remove -y "$PACKAGE" >> "$RUN_LOG" 2>&1
                else
                    sudo apt-get install -y --allow-downgrades "$PACKAGE=$OLD_VAL" >> "$RUN_LOG" 2>&1
                fi
                ;;
            FLATPAK)
                # OLD_VAL should be commit hash
                flatpak update -y --commit="$OLD_VAL" "$PACKAGE" >> "$RUN_LOG" 2>&1
                ;;
            SNAP)
                # Snap revert is simple, doesn't always need version, but lets try
                sudo snap revert "$PACKAGE" >> "$RUN_LOG" 2>&1
                ;;
            DNF)
                # DNF typically rolls back via transaction ID, not package.
                # If we logged transaction ID in OLD_VAL for a bulk action...
                if [[ "$PACKAGE" == "BULK_TRANSACTION" ]]; then
                    sudo dnf history undo -y "$OLD_VAL" >> "$RUN_LOG" 2>&1
                else
                    log "Skipping DNF single package rollback (not implemented safely)."
                fi
                ;;
        esac
    done

    log "Rollback process completed (Best Effort)."
}

if $ROLLBACK_MODE; then
    perform_rollback
    exit 0
fi

# --- Detection ---

MANAGERS=()

detect_managers() {
    log "Detecting package managers..."
    if command -v apt-get &> /dev/null; then MANAGERS+=("apt"); fi
    if command -v dnf &> /dev/null; then MANAGERS+=("dnf"); fi
    if command -v flatpak &> /dev/null; then MANAGERS+=("flatpak"); fi
    if command -v snap &> /dev/null; then MANAGERS+=("snap"); fi
}

# --- Update Retrieval ---

declare -A APT_UPDATES
declare -A FLATPAK_UPDATES
declare -A SNAP_UPDATES
# DNF is bulk only for now

fetch_updates() {
    log "Fetching updates..."
    
    for mgr in "${MANAGERS[@]}"; do
        case $mgr in
            apt)
                sudo DEBIAN_FRONTEND=noninteractive apt-get update -y >> "$RUN_LOG" 2>&1
                apt list --upgradable 2>/dev/null | grep -v "Listing..." > "$TEMP_DIR/apt_raw"
                while read -r line;
                do
                    pkg=$(echo "$line" | cut -d'/' -f1)
                    ver=$(echo "$line" | awk '{print $2}')
                    if [ -n "$pkg" ]; then APT_UPDATES["$pkg"]="$ver"; fi
                done < "$TEMP_DIR/apt_raw"
                ;;
            dnf)
                dnf check-update > "$TEMP_DIR/dnf_raw" 2>>"$RUN_LOG"
                ;;
            flatpak)
                flatpak remote-ls --updates --columns=application,name,commit > "$TEMP_DIR/flatpak_raw" 2>>"$RUN_LOG"
                while read -r line;
                do
                    app_id=$(echo "$line" | awk '{print $1}')
                    # Just storing name for UI
                    name=$(echo "$line" | cut -d' ' -f2-)
                    if [ -n "$app_id" ]; then FLATPAK_UPDATES["$app_id"]="$name"; fi
                done < "$TEMP_DIR/flatpak_raw"
                ;;
            snap)
                snap refresh --list > "$TEMP_DIR/snap_raw" 2>>"$RUN_LOG"
                tail -n +2 "$TEMP_DIR/snap_raw" | while read -r line;
                do
                     name=$(echo "$line" | awk '{print $1}')
                     ver=$(echo "$line" | awk '{print $2}')
                     if [ -n "$name" ]; then SNAP_UPDATES["$name"]="$ver"; fi
                done
                ;;
        esac
    done
}

# --- Selection ---

SELECTED_APT=()
SELECTED_FLATPAK=()
SELECTED_SNAP=()

present_plan() {
    if $NON_INTERACTIVE || ! command -v whiptail &> /dev/null; then
        for pkg in "${!APT_UPDATES[@]}"; do SELECTED_APT+=("$pkg"); done
        for pkg in "${!FLATPAK_UPDATES[@]}"; do SELECTED_FLATPAK+=("$pkg"); done
        for pkg in "${!SNAP_UPDATES[@]}"; do SELECTED_SNAP+=("$pkg"); done
        return
    fi

    ARGS=()
    for pkg in "${!APT_UPDATES[@]}"; do ARGS+=("APT:$pkg" "Update $pkg" "ON"); done
    for pkg in "${!FLATPAK_UPDATES[@]}"; do ARGS+=("FLATPAK:$pkg" "Update $pkg" "ON"); done
    for pkg in "${!SNAP_UPDATES[@]}"; do ARGS+=("SNAP:$pkg" "Update $pkg" "ON"); done

    if [ ${#ARGS[@]} -eq 0 ]; then
        if [[ " ${MANAGERS[*]} " =~ " dnf " ]]; then
             whiptail --msgbox "DNF updates detected. OK to proceed." 10 50
             return
        fi
        whiptail --msgbox "No updates found!" 10 40
        exit 0
    fi

    SELECTIONS=$(whiptail --title "System Updates" --checklist "Select packages:" 20 78 10 "${ARGS[@]}" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then exit 0; fi

    SELECTIONS="${SELECTIONS//\"/}"
    for sel in $SELECTIONS;
    do
        type=$(echo "$sel" | cut -d':' -f1)
        pkg=$(echo "$sel" | cut -d':' -f2)
        case $type in
            APT) SELECTED_APT+=("$pkg") ;;
            FLATPAK) SELECTED_FLATPAK+=("$pkg") ;;
            SNAP) SELECTED_SNAP+=("$pkg") ;;
        esac
    done
}

# --- Execution & Recording ---

BATCH_ID="BATCH_$(date +%s)"

perform_updates() {
    echo "Update Report - $(date)" > "$REPORT_FILE"
    
    # APT
    if [ ${#SELECTED_APT[@]} -gt 0 ]; then
        log "Processing APT updates..."
        # Capture old versions individually (slow but necessary for safe rollback)
        for pkg in "${SELECTED_APT[@]}"; do
            old_ver=$(dpkg -s "$pkg" 2>/dev/null | grep '^Version:' | awk '{print $2}')
            if [ -z "$old_ver" ]; then old_ver="NONE"; fi
            # We don't know new version for sure until installed, but we have target from fetch
            target_ver="${APT_UPDATES[$pkg]}"
            
            # Record intent
            record_transaction "$(date -Iseconds)" "$BATCH_ID" "APT" "$pkg" "UPDATE" "$old_ver" "$target_ver"
        done
        
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${SELECTED_APT[@]}" >> "$RUN_LOG" 2>&1
        echo "APT: Processed ${#SELECTED_APT[@]} packages." >> "$REPORT_FILE"
    fi

    # Flatpak
    if [ ${#SELECTED_FLATPAK[@]} -gt 0 ]; then
        log "Processing Flatpak updates..."
        for app in "${SELECTED_FLATPAK[@]}"; do
            # Get current commit
            current_commit=$(flatpak info "$app" | grep 'Commit:' | awk '{print $2}')
            
            flatpak update -y "$app" >> "$RUN_LOG" 2>&1
            
            # Get new commit
            new_commit=$(flatpak info "$app" | grep 'Commit:' | awk '{print $2}')
            
            record_transaction "$(date -Iseconds)" "$BATCH_ID" "FLATPAK" "$app" "UPDATE" "$current_commit" "$new_commit"
        done
        echo "Flatpak: Updated ${#SELECTED_FLATPAK[@]} apps." >> "$REPORT_FILE"
    fi

    # Snap
    if [ ${#SELECTED_SNAP[@]} -gt 0 ]; then
        log "Processing Snap updates..."
        for pkg in "${SELECTED_SNAP[@]}"; do
            # Snap version is loosely defined, rollback uses 'snap revert' which handles state internally
            # We record version for info
            old_ver=$(snap list "$pkg" | awk 'NR==2 {print $2}')
            
            sudo snap refresh "$pkg" >> "$RUN_LOG" 2>&1
            
            new_ver=$(snap list "$pkg" | awk 'NR==2 {print $2}')
            record_transaction "$(date -Iseconds)" "$BATCH_ID" "SNAP" "$pkg" "UPDATE" "$old_ver" "$new_ver"
        done
        echo "Snap: Updated ${#SELECTED_SNAP[@]} snaps." >> "$REPORT_FILE"
    fi

    # DNF (Bulk)
    if [[ " ${MANAGERS[*]} " =~ " dnf " ]]; then
        log "Running DNF Upgrade..."
        # Get last ID
        old_id=$(sudo dnf history | head -n 3 | tail -n 1 | awk '{print $1}')
        
        sudo dnf upgrade -y >> "$RUN_LOG" 2>&1
        
        new_id=$(sudo dnf history | head -n 3 | tail -n 1 | awk '{print $1}')
        
        # If ID changed, we record it
        if [ "$old_id" != "$new_id" ]; then
             # For DNF, we treat PACKAGE as "BULK_TRANSACTION" and OLD_VAL as the ID to undo
             record_transaction "$(date -Iseconds)" "$BATCH_ID" "DNF" "BULK_TRANSACTION" "UPDATE" "$new_id" "N/A"
             echo "DNF: System upgraded." >> "$REPORT_FILE"
        fi
    fi
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
        if sudo dnf needs-restarting -r &>/dev/null;
        then
             # Exit code 1 means reboot needed
             if [ $? -eq 1 ]; then REBOOT_REQUIRED=true; fi
        fi
    fi
    
    if $REBOOT_REQUIRED; then
        log "Reboot IS required."
        echo "" >> "$REPORT_FILE"
        echo "*** REBOOT REQUIRED ***" >> "$REPORT_FILE"
    else
        echo "No reboot required." >> "$REPORT_FILE"
    fi
}

send_email() {
    if [ -n "$EMAIL_ADDR" ]; then
        log "Sending email report to $EMAIL_ADDR..."
        if command -v mail &> /dev/null; then
             cat "$REPORT_FILE" | mail -s "EzUpdate Report - $(hostname)" "$EMAIL_ADDR"
        elif command -v sendmail &> /dev/null; then
             # Simple sendmail wrapper
             (
                 echo "Subject: EzUpdate Report - $(hostname)"
                 echo "To: $EMAIL_ADDR"
                 echo ""
                 cat "$REPORT_FILE"
             ) | sendmail -t
        elif command -v mutt &> /dev/null; then
             cat "$REPORT_FILE" | mutt -s "EzUpdate Report - $(hostname)" -- "$EMAIL_ADDR"
        else
             log "Error: No suitable mail client found (checked: mail, sendmail, mutt)."
        fi
    fi
}

# --- Main Flow ---

echo "Welcome to EzUpdate."
detect_managers
fetch_updates
present_plan
perform_updates
cleanup_system
check_reboot
send_email

echo ""
echo "----------------------------------------"
cat "$REPORT_FILE"
echo "----------------------------------------"
echo "Detailed logs: $LOG_DIR"

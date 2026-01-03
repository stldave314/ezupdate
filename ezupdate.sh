#!/bin/bash

# ezupdate.sh
# A multi-manager system update utility.
#
# Usage: ./ezupdate.sh [options]
# Options:
#   -h, --help    Show this help message.
#   -y, --yes     Non-interactive mode (automatically update all detected packages).

LOG_FILE="ezupdate_run.log"
REPORT_FILE="ezupdate_report.txt"
TEMP_DIR=$(mktemp -d)

# cleanup on exit
trap "rm -rf $TEMP_DIR" EXIT

log() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# --- Argument Parsing ---

NON_INTERACTIVE=false

show_help() {
    echo "EzUpdate - System Update Wrapper"
    echo ""
    echo "Usage: sudo ./ezupdate.sh [options]"
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help message and exit."
    echo "  -y, --yes     Non-interactive mode. Automatically selects all updates"
    echo "                and skips the confirmation UI. Ideal for cron jobs."
    echo ""
    echo "Supported Package Managers:"
    echo "  - APT (Debian/Ubuntu)"
    echo "  - DNF (Fedora/RHEL)"
    echo "  - Pacman (Arch Linux)"
    echo "  - Flatpak"
    echo "  - Snap"
    echo ""
}

# Parse arguments
for arg in "$@"; do
    case $arg in
        -h|--help)
            show_help
            exit 0
            ;; 
        -y|--yes)
            NON_INTERACTIVE=true
            ;; 
        *)
            echo "Unknown option: $arg"
            show_help
            exit 1
            ;; 
    esac
done

# --- Detection ---

MANAGERS=()

detect_managers() {
    log "Detecting package managers..."
    if command -v apt-get &> /dev/null; then
        MANAGERS+=("apt")
        log "Detected: APT"
    fi
    if command -v dnf &> /dev/null; then
        MANAGERS+=("dnf")
        log "Detected: DNF"
    fi
    if command -v pacman &> /dev/null; then
        MANAGERS+=("pacman")
        log "Detected: Pacman"
    fi
    if command -v flatpak &> /dev/null; then
        MANAGERS+=("flatpak")
        log "Detected: Flatpak"
    fi
    if command -v snap &> /dev/null; then
        MANAGERS+=("snap")
        log "Detected: Snap"
    fi
    
    if [ ${#MANAGERS[@]} -eq 0 ]; then
        echo "No supported package managers found."
        exit 1
    fi
}

# --- Update Retrieval & Planning ---

# Associative arrays to store update lists (format: "pkg_name description")
declare -A APT_UPDATES
declare -A DNF_UPDATES
declare -A PACMAN_UPDATES
declare -A FLATPAK_UPDATES
declare -A SNAP_UPDATES

fetch_updates() {
    log "Fetching updates..."
    
    for mgr in "${MANAGERS[@]}"; do
        case $mgr in
            apt)
                echo "Updating APT repositories..."
                # Use DEBIAN_FRONTEND=noninteractive to avoid some potential hangs
                sudo DEBIAN_FRONTEND=noninteractive apt-get update -y >> "$LOG_FILE" 2>&1
                
                # Parse apt list --upgradable
                apt list --upgradable 2>/dev/null | grep -v "Listing..." > "$TEMP_DIR/apt_raw"
                while read -r line; do
                    pkg=$(echo "$line" | cut -d'/' -f1)
                    ver=$(echo "$line" | awk '{print $2}')
                    if [ -n "$pkg" ]; then
                        APT_UPDATES["$pkg"]="Upgrade_to_$ver"
                    fi
                done < "$TEMP_DIR/apt_raw"
                ;; 
            dnf)
                echo "Checking DNF updates..."
                dnf check-update > "$TEMP_DIR/dnf_raw" 2>>"$LOG_FILE"
                # DNF output parsing is skipped for MVP; treated as bulk update.
                ;; 
            flatpak)
                echo "Checking Flatpak updates..."
                flatpak remote-ls --updates --columns=application,name > "$TEMP_DIR/flatpak_raw" 2>>"$LOG_FILE"
                while read -r line; do
                    app_id=$(echo "$line" | awk '{print $1}')
                    name=$(echo "$line" | cut -d' ' -f2-)
                    if [ -n "$app_id" ]; then
                        FLATPAK_UPDATES["$app_id"]="$name"
                    fi
                done < "$TEMP_DIR/flatpak_raw"
                ;; 
            snap)
                echo "Checking Snap updates..."
                snap refresh --list > "$TEMP_DIR/snap_raw" 2>>"$LOG_FILE"
                # Skip header
                tail -n +2 "$TEMP_DIR/snap_raw" | while read -r line; do
                     name=$(echo "$line" | awk '{print $1}')
                     ver=$(echo "$line" | awk '{print $2}')
                     if [ -n "$name" ]; then
                        SNAP_UPDATES["$name"]="$ver"
                     fi
                done
                ;; 
        esac
    done
}

# --- Presentation & Selection ---

SELECTED_APT=()
SELECTED_FLATPAK=()
SELECTED_SNAP=()

present_plan() {
    # If non-interactive OR whiptail missing OR no specific updates parsed (DNF), select all.
    if $NON_INTERACTIVE || ! command -v whiptail &> /dev/null; then
        if $NON_INTERACTIVE; then
            log "Non-interactive mode detected. Proceeding with all updates."
        else
            log "Whiptail not found. Proceeding with all updates."
        fi
        
        # Auto-select all known
        for pkg in "${!APT_UPDATES[@]}"; do SELECTED_APT+=("$pkg"); done
        for pkg in "${!FLATPAK_UPDATES[@]}"; do SELECTED_FLATPAK+=("$pkg"); done
        for pkg in "${!SNAP_UPDATES[@]}"; do SELECTED_SNAP+=("$pkg"); done
        return
    fi

    # Build Checklist Args
    ARGS=()
    
    # APT
    for pkg in "${!APT_UPDATES[@]}"; do
        ARGS+=("APT:$pkg" "Update $pkg (${APT_UPDATES[$pkg]})" "ON")
    done
    
    # Flatpak
    for pkg in "${!FLATPAK_UPDATES[@]}"; do
        ARGS+=("FLATPAK:$pkg" "Update $pkg (${FLATPAK_UPDATES[$pkg]})" "ON")
    done
    
    # Snap
    for pkg in "${!SNAP_UPDATES[@]}"; do
        ARGS+=("SNAP:$pkg" "Update $pkg (${SNAP_UPDATES[$pkg]})" "ON")
    done

    # If no individual packages found but Managers were detected (e.g. only DNF),
    # we might still want to proceed.
    if [ ${#ARGS[@]} -eq 0 ]; then
        # Check if DNF is present, as we don't list DNF pkgs individually yet.
        if [[ " ${MANAGERS[*]} " =~ " dnf " ]]; then
             whiptail --msgbox "DNF updates detected (bulk mode). Press OK to proceed." 10 50
             return
        fi
        
        whiptail --msgbox "No specific updates found!" 10 40
        exit 0
    fi

    SELECTIONS=$(whiptail --title "System Updates" --checklist \
    "Select packages to update:" 20 78 10 \
    "${ARGS[@]}" 3>&1 1>&2 2>&3)
    
    exit_status=$?
    if [ $exit_status -ne 0 ]; then
        echo "Update cancelled by user."
        exit 0
    fi

    # Parse selections
    # Remove quotes
    SELECTIONS="${SELECTIONS//"/}"
    
    for sel in $SELECTIONS; do
        type=$(echo "$sel" | cut -d':' -f1)
        pkg=$(echo "$sel" | cut -d':' -f2)
        
        case $type in
            APT) SELECTED_APT+=("$pkg") ;; 
            FLATPAK) SELECTED_FLATPAK+=("$pkg") ;; 
            SNAP) SELECTED_SNAP+=("$pkg") ;; 
        esac
    done
}

# --- Execution ---

perform_updates() {
    echo "Starting updates..." > "$REPORT_FILE"
    
    # APT
    if [ ${#SELECTED_APT[@]} -gt 0 ]; then
        log "Updating APT packages: ${SELECTED_APT[*]}"
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${SELECTED_APT[@]}" >> "$LOG_FILE" 2>&1
        if [ $? -eq 0 ]; then
            echo "APT: Successfully updated ${#SELECTED_APT[@]} packages." >> "$REPORT_FILE"
        else
            echo "APT: Errors occurred. Check log." >> "$REPORT_FILE"
        fi
    fi
    
    # DNF (Bulk)
    if [[ " ${MANAGERS[*]} " =~ " dnf " ]]; then
        # If interactive, user already confirmed via "OK" in present_plan or didn't cancel
        log "Running DNF Upgrade..."
        sudo dnf upgrade -y >> "$LOG_FILE" 2>&1
         if [ $? -eq 0 ]; then
            echo "DNF: Update complete." >> "$REPORT_FILE"
        fi
    fi

    # Flatpak
    if [ ${#SELECTED_FLATPAK[@]} -gt 0 ]; then
        log "Updating Flatpaks..."
        flatpak update -y "${SELECTED_FLATPAK[@]}" >> "$LOG_FILE" 2>&1
        echo "Flatpak: Updated ${#SELECTED_FLATPAK[@]} apps." >> "$REPORT_FILE"
    fi

    # Snap
    if [ ${#SELECTED_SNAP[@]} -gt 0 ]; then
        log "Updating Snaps..."
        for snap_pkg in "${SELECTED_SNAP[@]}"; do
            sudo snap refresh "$snap_pkg" >> "$LOG_FILE" 2>&1
        done
        echo "Snap: Updated ${#SELECTED_SNAP[@]} snaps." >> "$REPORT_FILE"
    fi
}

# --- Cleanup ---

cleanup_system() {
    log "Cleaning up..."
    echo "Running cleanup..." >> "$REPORT_FILE"
    
    if [[ " ${MANAGERS[*]} " =~ " apt " ]]; then
        sudo apt-get autoremove -y >> "$LOG_FILE" 2>&1
        sudo apt-get clean >> "$LOG_FILE" 2>&1
    fi
    
    if [[ " ${MANAGERS[*]} " =~ " flatpak " ]]; then
        flatpak uninstall --unused -y >> "$LOG_FILE" 2>&1
    fi
    
    if [[ " ${MANAGERS[*]} " =~ " dnf " ]]; then
        sudo dnf autoremove -y >> "$LOG_FILE" 2>&1
    fi
}

# --- Main ---

echo "Welcome to EzUpdate."
detect_managers
fetch_updates
present_plan
perform_updates
cleanup_system

echo ""
echo "----------------------------------------"
cat "$REPORT_FILE"
echo "----------------------------------------"
echo "Log saved to $LOG_FILE"
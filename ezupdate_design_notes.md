# ezupdate.sh - Design & Implementation Notes

## Goal
Create a shell script to automate system updates across multiple package managers (APT, DNF, Pacman/AUR, Flatpak, Snap) with a user interface for reviewing and potentially deselecting updates.

## Architecture

### 1. Detection Phase
The script will check for the existence of package manager binaries using `command -v`.
Supported managers:
- `apt` (Debian/Ubuntu)
- `dnf` (Fedora/RHEL)
- `pacman` (Arch Linux)
- `flatpak` (Universal)
- `snap` (Universal)
- `brew` (Homebrew on Linux - optional addition)

### 2. Update Retrieval (The "Plan")
For each detected manager, the script will fetch the list of available updates without applying them.
- **APT**: `sudo apt-get update` then `apt list --upgradable`
- **DNF**: `dnf check-update`
- **Pacman**: `checkupdates` (requires pacman-contrib) or `pacman -Qu`
- **Flatpak**: `flatpak remote-ls --updates --columns=application,name`
- **Snap**: `snap refresh --list`

### 3. User Interface & Deselection
This is the most challenging part in a portable shell script.
- **Primary Tool**: `whiptail` (usually available on most distros) or `dialog`.
- **Fallback**: Simple text prompt (Y/N) if UI tools are missing.
- **Granularity**:
    - Ideally, we parse the output of each manager to build a checklist.
    - **Constraint**: Parsing text output from CLI tools is brittle. Formats change.
    - **Strategy**: I will implement a "Best Effort" parser for `apt`, `flatpak`, and `snap`.
    - If parsing fails or is too complex for a specific manager, the fallback will be a bulk "Update [Manager Name]" toggle.

### 4. Execution
Based on the user's selection:
- If "All" selected: Run standard full upgrade commands (e.g., `apt-get dist-upgrade`).
- If specific packages selected: Run install/upgrade commands for those specific packages.
    - *Note*: Partial upgrades can sometimes be dangerous (dependency issues) on systems like Arch (Pacman). The script should warn about partial upgrades if applicable.

### 5. Cleanup
- `apt-get autoremove`, `apt-get clean`
- `dnf autoremove`
- `flatpak uninstall --unused`
- `pacman -Sc` (interactive, maybe skip or use `noconfirm` carefully)

### 6. Reporting
Generate a summary of what was updated and any errors encountered.

## Future Improvements / Known Limitations
- **AUR Support**: `yay` or `paru` handling needs to be robust.
- **Dependency Hell**: Manually deselecting a library package but keeping the app that needs it might break things. The script assumes the package manager handles dependency resolution (e.g., if user selects App A, PM pulls in Lib B).
- **Parsing Robustness**: The regex for parsing `apt list` or `snap refresh --list` might need tweaking for different versions/locales.

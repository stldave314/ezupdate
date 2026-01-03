# EzUpdate

**EzUpdate** is a lightweight, unified system update wrapper for Linux. It automatically detects installed package managers (APT, DNF, Pacman, Flatpak, Snap) and provides a single command to update your entire system.

It features an interactive terminal UI (TUI) allowing you to review and select specific updates, or a non-interactive mode for automated maintenance.

## Features

-   **Multi-Manager Support:** Automatically detects and handles:
    -   `apt` (Debian, Ubuntu, Linux Mint, etc.)
    -   `dnf` (Fedora, RHEL, CentOS)
    -   `pacman` (Arch Linux, Manjaro) - *Detection only in this version*
    -   `flatpak` (Universal)
    -   `snap` (Universal)
-   **Interactive Selection:** Uses `whiptail` to present a checklist of available updates. You can deselect specific packages you don't want to upgrade yet.
-   **Automated Cleanup:** Automatically runs cleanup commands (like `autoremove` and cache cleaning) after updates are applied.
-   **Logging:** Keeps a detailed log of all operations (`ezupdate_run.log`) and a summary report (`ezupdate_report.txt`).
-   **Non-Interactive Mode:** Can be run via cron or scripts with the `-y` flag to auto-accept all updates.

## Installation

1.  Clone this repository:
    ```bash
    git clone https://github.com/YOUR_USERNAME/ezupdate.git
    cd ezupdate
    ```

2.  Make the script executable:
    ```bash
    chmod +x ezupdate.sh
    ```

## Usage

To run EzUpdate, simply execute the script. Sudo privileges are required for system updates.

```bash
sudo ./ezupdate.sh
```

### Options

| Flag | Long Flag | Description |
| :--- | :--- | :--- |
| `-h` | `--help` | Show the help message and exit. |
| `-y` | `--yes` | **Non-Interactive Mode.** Automatically select all updates and skip the UI. Useful for automated maintenance scripts. |

### Example: Automated Nightly Updates

You can add EzUpdate to your root crontab to run nightly at 3 AM:

1.  Open crontab: `sudo crontab -e`
2.  Add the line:
    ```cron
    0 3 * * * /path/to/ezupdate/ezupdate.sh -y
    ```

## Requirements

-   **Bash**
-   **Whiptail** (optional, for the interactive UI).
    -   Ubuntu/Debian: `sudo apt install whiptail`
    -   Fedora: `sudo dnf install newt`
    -   *If whiptail is missing, the script defaults to updating all packages.*

## How It Works

1.  **Detection:** The script checks your path for package manager binaries.
2.  **Fetch:** It runs the "check update" command for each detected manager (e.g., `apt update`, `flatpak remote-ls`).
3.  **Plan:** It compiles a list of upgradable packages.
4.  **Present:** (Interactive mode) It shows you the list. You uncheck what you want to skip.
5.  **Execute:** It runs the specific install commands for selected packages (or bulk upgrade for DNF).
6.  **Cleanup:** It runs maintenance commands like `apt autoremove` or `flatpak uninstall --unused`.

## License

MIT License. Feel free to fork and modify.

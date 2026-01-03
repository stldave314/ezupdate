# EzUpdate

**EzUpdate** is a robust, fully automated system update utility for Linux. It unifies maintenance for APT, DNF, Flatpak (System & User), and Snap into a single, reliable workflow with advanced safety features like rollback, transaction logging, and dual-state reporting.

## Features

-   **Multi-Manager Support:** Automatically detects and handles `apt`, `dnf`, `flatpak`, and `snap`.
-   **Fully Automated:** Designed for speed and reliability, it automatically applies the default upgrade paths for all detected managers.
-   **Dual-State Reporting:** Generates a comprehensive report showing both **Pending Updates** (what was found) and **Applied Updates** (what was successfully changed).
-   **User-Level Flatpak Support:** Automatically detects and updates both system-wide and user-installed Flatpaks.
-   **Rollback Capability:** Records transaction history and allows you to revert changes if an update causes issues.
-   **Detailed Logging:** Maintains a machine-readable history (CSV) and verbose execution logs.
-   **Email Reporting:** Optionally email the detailed update summary to an administrator.
-   **Reboot Detection:** Automatically checks if a system reboot is required after updates.
-   **Automated Cleanup:** Runs post-update cleanup (autoremove, cache clearing).

## Installation

1.  Clone this repository:
    ```bash
    git clone https://github.com/stldave314/ezupdate.git
    cd ezupdate
    ```

2.  Make the script executable:
    ```bash
    chmod +x ezupdate.sh
    ```

## Usage

EzUpdate requires sudo privileges to perform system-level updates.

```bash
sudo ./ezupdate.sh [options]
```

### Options

| Flag | Description |
| :--- | :--- |
| `-h`, `--help` | Show the help message. |
| `--rollback <file>` | **Rollback Mode.** Revert changes based on a log file. Use `latest` to rollback the last run. |
| `--email <address>` | Email the dual-state report to the specified address upon completion. |
| `--log-dir <path>` | Specify a custom directory for logs (Default: `/var/log/ezupdate` or `~/.ezupdate/logs`). |

## Examples

**Run All Updates:**
```bash
sudo ./ezupdate.sh
```

**Automated Maintenance with Email Report:**
```bash
sudo ./ezupdate.sh --email admin@example.com
```

**Rollback the Last Update Batch:**
```bash
sudo ./ezupdate.sh --rollback latest
```

## Rollback Details

EzUpdate tracks the specific versions or commit hashes of updated packages in its history log.
-   **APT:** Attempts to install the previously recorded version (`apt install pkg=old_ver`).
-   **Flatpak:** Reverts to the previous recorded commit hash.
-   **Snap:** Uses `snap revert`.
-   **DNF:** Uses `dnf history undo`.

## Logs

Logs are stored in `/var/log/ezupdate/` (if run as root) or `~/.ezupdate/logs/`.
-   **history.csv**: Machine-readable transaction log used for rollbacks.
-   **ezupdate_run.log**: Verbose output of every command executed.
-   **ezupdate_report.txt**: The dual-state summary (Pending vs. Applied) of the last run.

## License

MIT License.

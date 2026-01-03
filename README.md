# EzUpdate

**EzUpdate** is a comprehensive, multi-manager system update utility for Linux. It unifies updates for APT, DNF, Flatpak, and Snap into a single workflow with advanced safety features like rollback, logging, and reporting.

## Features

-   **Multi-Manager Support:** Automatically detects and handles `apt`, `dnf`, `flatpak`, and `snap`.
-   **Interactive & Automated Modes:** Choose between a TUI checklist (`whiptail`) or a fully automated non-interactive mode.
-   **Rollback Capability:** Record transaction history and revert changes if something goes wrong.
-   **Detailed Logging:** Maintains a machine-readable history (CSV) and verbose execution logs.
-   **Email Reporting:** Optionally email the update summary to an administrator.
-   **Reboot Detection:** Automatically checks if a system reboot is required after updates.
-   **Automated Cleanup:** Runs post-update cleanup (autoremove, cache clearing).

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

```bash
sudo ./ezupdate.sh [options]
```

### Options

| Flag | Description |
| :--- | :--- |
| `-h`, `--help` | Show the help message. |
| `-y`, `--yes` | **Non-Interactive Mode.** Auto-accept all updates. Ideal for cron jobs. |
| `--rollback <file>` | **Rollback Mode.** Revert changes based on a log file. Use `latest` to rollback the last run. |
| `--email <address>` | Email the report to the specified address upon completion. |
| `--log-dir <path>` | Specify a custom directory for logs (Default: `/var/log/ezupdate` or `~/.ezupdate/logs`). |

## Examples

**Standard Interactive Update:**
```bash
sudo ./ezupdate.sh
```

**Automated Nightly Update with Email Report:**
```bash
sudo ./ezupdate.sh -y --email admin@example.com
```

**Rollback the Last Update:**
```bash
sudo ./ezupdate.sh --rollback latest
```

## Rollback Details

EzUpdate tracks the specific versions or commit hashes (for Flatpak) of updated packages.
-   **APT:** Attempts to install the previously installed version (`apt install pkg=old_ver`). *Note: Requires the old version to be present in repositories/cache.*
-   **Flatpak:** Reverts to the previous commit hash.
-   **Snap:** Uses `snap revert`.
-   **DNF:** Uses `dnf history undo`.

## Logs

Logs are stored in `/var/log/ezupdate/` (if run as root) or `~/.ezupdate/logs/`.
-   `history.csv`: Machine-readable transaction log used for rollbacks.
-   `ezupdate_run.log`: Verbose output of all commands executed.
-   `ezupdate_report.txt`: Summary of the last run.

## License

MIT License.
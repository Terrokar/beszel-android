# Changelog

## [1.3.0] - 2026-10-12

Brings the app in line with Beszel hub 0.21 and fixes the open issues.

### Added
- **MFA / one-time code login** (#8): when the hub requires MFA (`MFA_OTP=true`) the app asks for the emailed code. Password-less OTP login and OAuth2 / OIDC providers configured on the hub are supported too.
- **Chart time ranges** (#5): Live (1 s realtime stream), 1 hour, 12 hours, 24 hours, 1 week and 30 days, using the same `system_stats` types as the web UI. The chosen range is remembered.
- **Multiple disks** (#3): extra filesystems (`EXTRA_FILESYSTEMS`) with usage and I/O charts, cumulative read/write totals and ZFS / btrfs storage pools.
- **S.M.A.R.T.** (#3): disk health, temperature, power-on hours, power cycles and the full attribute table, with a refresh button.
- New detail tabs following the Beszel web UI: CPU time breakdown and load average, memory (buffers/cache, ZFS ARC, swap), network bandwidth per interface, temperatures, fans, batteries, GPU usage / VRAM / power / engines, Docker & Podman containers (with logs and inspect info), systemd services (with logs).
- Overview tab with `system_details` (OS name, kernel, CPU model, architecture, memory), agent version, connection type, pending package updates and Wi-Fi signal.
- Hub alerts: alert history (active and resolved), configured alert rules, and a notification when the hub raises a new alert.
- Dashboard: search, paused / pending status, status filter, sort by status, GPU and temperature, failed services and pending updates badges.
- **Self-signed / private CA certificates** (#6): the app shows the certificate fingerprint and lets you trust it for that host (mkcert, `.internal`, `.lan`, `.home.arpa`, …). Any host name, port or sub-path is accepted; `http://` is tried when no scheme is given and `https://` is not reachable. Connection errors now say what went wrong.
- Uzbek translation; system / light / dark theme option.
- GitHub Actions workflow that builds release APKs.

### Fixed
- **Logout** (#7): asks for confirmation, signs out, clears the stored session, PIN and biometric setting and returns to the server setup screen. A logout button was also added to the user screen.
- **App icon** (#2): adaptive icon with a full-bleed background, no more blank corners.
- **Chinese** (#4): included and selectable (rebuild of the release).
- Network and disk I/O values from current agents were shown in the wrong unit; legacy MB/s values are still supported.
- OS icon is detected from `info.os` instead of the kernel string.
- History charts mixed all aggregation levels; they now query the right `type` per range.
- Local threshold alerts were suppressed forever after the first one; each condition now notifies again after it clears.

## [1.2.0] - 2026-01-11

### Added
- **Biometric Authentication**: 
  - Added optional Fingerprint/Face ID protection.
  - Integration with PIN security: Auto-prompt on unlock.
  - User settings toggle to enable/disable biometrics.
- **Enhanced Detail View (Task Manager Style)**:
  - Completely redesigned system detail screen.
  - Added per-core CPU usage visualization.
  - Added dedicated tabs/panels for CPU, Memory, Disk, and Network.
  - Real-time charts for all metrics.
  - Detailed Interface statistics (upload/download rates per interface).
- **iOS Support**:
  - Full compatibility with iOS 14+.
  - **TrollStore Support**: GitHub Action workflow to generate unsigned IPA.
- **Localization**:
  - Added/Updated translations for English, Chinese (Simplified), and Russian.

### Changed
- **Network Monitoring**:
  - Improved network traffic calculation to aggregate all interface deltas for accuracy.
  - Adjusted unit formatting for network speeds.
- **MainActivity**:
  - Updated Android `MainActivity` to `FlutterFragmentActivity` for better plugin compatibility.

---

## [1.1.0] - 2025-12-16

### Added
- **Offline Mode**: 
  - Implemented a dedicated "No internet connection" screen with a refresh button.
  - Gracefully intercepts network errors (`ClientException`, `SocketException`) instead of showing generic error text.
- **OS Recognition**: 
  - Added visual detection for **Windows** (`assets/windows.png`) and **Linux** (`assets/linux.png`) servers.
  - Automatically identifies the OS from system info and displays the appropriate icon on the dashboard card.
- **Notification Center**:
  - Added a **Notification Bell** with a **Red Badge** to the Dashboard AppBar to indicate unread alerts.
  - Implemented **Smart Suppression**: Prevents duplicate alerts for the same issue until the user acknowledges (clears) them.
  - Added `POST_NOTIFICATIONS` permission support for Android 13+.

### Changed
- **User Interface**:
  - Removed the redundant "Alerts" option from the user popup menu (now accessible via the AppBar bell).
  - Improved `System` model parsing to extract kernel/OS information.
- **Alert Logic**:
  - `AlertManager` now tracks state (unread/read) to coordinate with the UI badge.
  - Notifications are now requested properly on app startup.

### Fixed
- **Permission Issues**: Resolved `Permission denied` for notifications on newer Android versions.
- **UI Bugs**: Fixed the "question mark" icon issue for Linux systems by updating fallback logic.

---

## [1.0.0] - 2025-12-15

### Added
- **Custom Pull-to-Refresh**: Implemented a custom refresh indicator on the Dashboard that spins the app icon (`assets/icon.png`) during refresh.
- **Startup Alert Checks**: The app now immediately checks system health upon Dashboard load. If a system is *already* overloaded (>80%) when the app starts, an alert is triggered instantly.
- **Safe Initialization**: Added `postFrameCallback` to Dashboard initialization to ensure the UI renders immediately before starting heavy background services.

### Changed
- **Alert Thresholds**: Updated CPU, RAM, and Disk alert thresholds to a uniform **> 80%**.
- **PIN Security Flow**: Restored PIN Code functionality with automatic cleanup on Logout.
- **Alert History**: Capped local alert history to **50 items**.

### Fixed
- **Startup Crash**: Resolved `Unhandled Exception: Widget has been unmounted`.
- **Emulator Freeze**: Mitigated initialization performance issues.

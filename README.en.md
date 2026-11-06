# Private Ledger

[简体中文](README.md) · English

Private Ledger is a self-hosted personal finance app. A Windows computer runs the sync service and stores the main ledger, while the Android client keeps a local copy. After the first connection, you can record transactions, make edits, and view reports offline. The phone exchanges pending changes and new transactions with the computer when the connection is available.

## Features

- **Record and edit transactions.** Enter income or expenses and update the amount, date, category, tags, notes, and whether an entry counts toward reports.
- **Import statements.** Choose Alipay or WeChat for supported statement exports, or choose Standard CSV for generic statements and supported QianJi CSV files. Review the preview and duplicate flags before confirming the import.
- **View reports offline.** The overview, monthly and yearly reports, category breakdowns, and monthly trends update when you save a transaction. Linked refunds are applied to the month of the original purchase.
- **Sync and export.** Exchange ledger changes with the computer and export complete or redacted CSV files by month or year while connected.

## Install and connect

1. Download `private-ledger-0.4.1-full.zip` from the [v0.4.1 release](https://github.com/scp007007/private-ledger/releases/tag/v0.4.1) and extract the full archive. Use the `arm64-v8a` APK on most Android phones and the `x86_64` APK on emulators using an x86_64 image.
2. Install Python 3.12 on Windows. For the first run, open `setup-ledger-server.cmd` from the extracted folder to install the dependencies. This step requires internet access.
3. Open `start-ledger-server.cmd` and start the service. When the status indicates that the service is ready, copy the address and connection token shown in the desktop window.
4. Connect the phone and computer to the same trusted local network or use an existing private VPN. Enter the server's base address in the app, run the network check, then enter the token and connect.

To upgrade, install the new APK over the existing app signed with the same key. This preserves the local ledger and pending edits. The 0.4.1 mobile app works with the existing 0.4.0 desktop service. Release APKs use the project's internal test signing key. A locally built APK signed with a different key cannot replace an existing install.

## Everyday use

| Task | What to do |
| --- | --- |
| Add or edit a transaction | Tap the add button (「记一笔」), or open an existing entry from Transactions (「流水」). Save when done. |
| Import past transactions | Export the statement, choose its source and file, review the preview page by page, then confirm. Import accepts CSV or a ZIP containing exactly one CSV. Convert Excel files first. |
| View spending reports | Open Overview (「总览」) or Reports (「统计」), then choose a month or year. Charts include pending local changes. |
| Sync the phone and computer | Tap Sync Ledger (「同步账单」) after reconnecting, or enable automatic sync under Settings (「我的」). Review and resolve any conflicts in the app. |
| Export for review or analysis | Connect to the computer, open Reports, and choose the period and export type. Redacted exports retain dates and amounts. |

This version imports statement files. The desktop service must be online for the initial connection, import review, server-side import rules, and CSV export.

## Technology and data flow

| Layer | Technology | Responsibility |
| --- | --- | --- |
| Mobile app | Flutter, Dart, Material | Transaction editor, charts, import preview, and sync interface |
| Mobile storage | SQLite (sqflite), flutter_secure_storage | Local ledger copy and pending operations, with connection tokens in system secure storage |
| Desktop service | Python 3.12, FastAPI, Uvicorn | Token-authenticated HTTP API for sync, import review, and CSV export |
| Main ledger | SQLite | Transactions, versions, and import rules, with amounts stored as integer cents |
| Windows launcher | PowerShell, WinForms, DPAPI | Start and stop the service, show its address, check connectivity, and protect the local token |
| Build and verification | Gradle, Android SDK, Flutter Test, pytest | APK builds and tests for the client, API, and statement parsing |

Saving a transaction updates the local ledger and queues the operation for sync. Reports use that local ledger directly. Once reconnected, the phone uploads pending operations and downloads new transactions through the API. The server uses record versions to detect conflicting edits. On Windows, the default database and protected token live under `%LOCALAPPDATA%\PrivateLedger`.

Use plain HTTP on a trusted local network. For access across networks, use an encrypted private VPN or HTTPS. CSV exports are useful for review and analysis. Keep a separate backup of the desktop SQLite database for full ledger recovery.

## Build and test from source

See the [mobile client](ledger-app/mobile) and [desktop service](ledger-app/server) directories. The mobile project was verified with Flutter 3.47.5 and Dart 3.13.4. After installing Flutter and the Android SDK, run the following from the repository root:

```powershell
Set-Location ledger-app/mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --release --split-per-abi --target-platform=android-arm64,android-x64
```

To test the Windows service, start from the repository root:

```powershell
Set-Location ledger-app/server
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
.\.venv\Scripts\python.exe -m pytest -q
```

Additional documentation in Chinese: [Getting started](开始使用.md) · [Mobile client](ledger-app/mobile/README.md) · [Service and API](ledger-app/server/README.md) · [Import formats](ledger-app/server/app/importers/README.md) · [Connection troubleshooting and privacy](ledger-app/CONNECTION-PRIVACY.md)

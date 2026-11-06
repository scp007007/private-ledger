# 私有账本 · Private Ledger

简体中文 · [English](README.en.md)

私有账本是一套自托管的个人记账工具。Windows 电脑运行同步服务并保存主账本，Android 手机保存本地副本。首次连接后，手机可以离线记账、编辑流水和查看统计。重新连上电脑时，手机会同步待提交的修改和电脑端的新流水。

## 能做什么

- **手动记账和编辑**：新增收入或支出，修改金额、日期、分类、标签、备注和是否计入统计。
- **账单导入**：导入支付宝、微信导出的受支持文件，或选择「标准 CSV」导入通用账单和受支持的钱迹 CSV。先看预览与重复提示，确认后才写入账本。
- **离线统计**：总览、月报、年报、分类占比和月度趋势根据手机流水计算，离线保存后立即更新。关联退款抵扣原消费月份。
- **流水同步和导出**：联网后可同步账本。连接电脑时可按月或按年导出完整或脱敏 CSV。

## 安装与首次连接

1. 从 [v0.4.1 发行版](https://github.com/scp007007/private-ledger/releases/tag/v0.4.1) 下载并解压 `private-ledger-0.4.1-full.zip`。常见 Android 手机用 `arm64-v8a` APK，使用 x86_64 镜像的模拟器用 `x86_64` APK。
2. 在 Windows 安装 Python 3.12。首次运行时，双击解压目录中的 `setup-ledger-server.cmd`，联网安装依赖。
3. 双击 `start-ledger-server.cmd`，点击「启动服务」。显示「服务就绪」后，复制电脑端显示的地址和连接令牌。
4. 手机和电脑接入同一个可信局域网，或使用已配置好的私有 VPN。在手机端填写服务器根地址，先检查网络，再填入令牌并连接账本。

旧版用户可直接覆盖安装同签名 APK，保留手机账本和待同步记录。0.4.1 手机端可连接现有 0.4.0 电脑端。发行版采用项目的内部测试签名，自行构建的不同签名 APK 无法覆盖安装。

## 日常用法

| 想做什么 | 怎么操作 |
| --- | --- |
| 新增或修改一笔 | 点「记一笔」，或从「流水」打开已有记录，填写后保存。 |
| 导入历史账单 | 先导出账单，在手机上选来源和文件，逐页核对预览，再确认导入。当前支持 CSV 或只包含一个 CSV 的 ZIP。Excel 文件需先转换。 |
| 看月报、年报和消费占比 | 打开「总览」或「统计」，切换月份或年度。待同步的本机修改已计入图表。 |
| 同步手机和电脑 | 恢复连接后点「同步账单」，或在「我的」启用自动同步。同步冲突可在手机端核对后处理。 |
| 导出给自己备份或分析 | 连接电脑后在「统计」选择导出期间和完整或脱敏版本。脱敏版仍保留日期和金额。 |

当前版本通过账单文件导入。首次连接、账单导入审核、服务器导入规则和 CSV 导出需要电脑端在线。

## 技术栈与数据流

| 层 | 技术 | 职责 |
| --- | --- | --- |
| 手机端 | Flutter、Dart、Material | 流水编辑、图表、导入预览和同步界面 |
| 手机本地存储 | SQLite（sqflite）、flutter_secure_storage | 保存流水副本与待同步操作，连接令牌使用系统安全存储 |
| 电脑端 | Python 3.12、FastAPI、Uvicorn | 提供带令牌认证的 HTTP API，处理同步、导入审核和 CSV 导出 |
| 主账本 | SQLite | 保存流水、版本和导入规则，以整数分记录金额 |
| Windows 启动器 | PowerShell、WinForms、DPAPI | 启停服务、显示地址、检查连接并保护本机令牌 |
| 构建与验证 | Gradle、Android SDK、Flutter Test、pytest | 构建 APK 并测试客户端、API 和账单解析 |

手机保存一笔流水时，会先写入本地账本和待同步队列。月报和年报直接根据这份流水计算。恢复连接后，手机通过 API 提交修改并下载新流水，电脑端用版本号检测冲突。Windows 默认将主数据库与受保护的连接令牌保存在 `%LOCALAPPDATA%\PrivateLedger`。

局域网 HTTP 应用于可信网络。跨网络访问可用加密私有 VPN 或 HTTPS。导出的 CSV 适合查阅和分析，完整恢复账本请另行备份电脑端 SQLite 数据库。

## 从源码开发

源码位于 [手机端](ledger-app/mobile) 和 [电脑端](ledger-app/server)。已验证的手机工具链为 Flutter 3.47.5 / Dart 3.13.4。安装 Flutter 和 Android SDK 后，从仓库根目录运行：

```powershell
Set-Location ledger-app/mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --release --split-per-abi --target-platform=android-arm64,android-x64
```

从仓库根目录运行 Windows 服务测试：

```powershell
Set-Location ledger-app/server
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
.\.venv\Scripts\python.exe -m pytest -q
```

更多说明：[开始使用](开始使用.md) · [手机端](ledger-app/mobile/README.md) · [服务与 API](ledger-app/server/README.md) · [导入格式](ledger-app/server/app/importers/README.md) · [连接排查与隐私](ledger-app/CONNECTION-PRIVACY.md)

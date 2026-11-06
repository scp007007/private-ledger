# 私有账本 0.4.1

手机端用 Flutter，Windows 同步服务用 FastAPI 和 SQLite。已有账本可在手机上离线记账、编辑和查看统计，连接电脑后同步流水。

1. 从发行版下载并完整解压软件包。安卓手机使用 ARM64 APK，x86_64 模拟器使用对应安装包。
2. Windows 首次使用需安装 Python 3.12，然后双击 `setup-ledger-server.cmd` 安装服务依赖。此步骤需要联网。
3. 双击 `start-ledger-server.cmd`，点击“启动服务”，按 [开始使用](开始使用.md) 将手机连接到电脑。

源码在 `ledger-app/mobile` 和 `ledger-app/server`。开发时使用 Flutter SDK 和 Android 工具链，在手机源码目录运行 `flutter pub get` 和 `flutter test`。电脑端的本地开发、测试和部署方法见 [服务说明](ledger-app/server/README.md)。

安装包使用项目现有的内部测试签名。源码构建使用你自己的本地签名，签名不同的 APK 无法覆盖安装。

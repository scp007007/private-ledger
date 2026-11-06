# 自托管账本服务（Windows）

此服务保存主账本，提供导入、同步、月报和 CSV 导出。手机离线修改会在联网后通过版本号同步。金额在 API 和数据库中均使用整数分。

## 本机启动

### 本项目 Windows 一键启动（推荐）

双击项目 `outputs/start-ledger-server.cmd` 打开电脑端窗口，默认选取局域网网卡，点击“启动服务”。等到“服务就绪”，点击“复制地址”填到手机，先做免令牌网络检查，再点击“复制连接令牌”完成手机连接。最小化窗口可继续同步；关闭窗口会询问是否停止服务。

窗口右上角可切换简体中文和英文，选择会保存在当前 Windows 用户的本机设置中。

窗口复用已有 Python 虚拟环境，并将固定访问令牌通过 Windows DPAPI 加密保存在 `%LOCALAPPDATA%\PrivateLedger\api-token.dpapi`。首次可在输入框中填原令牌，留空才生成；以后复用。主账本默认复用同目录的 `ledger.sqlite3`；自定义 `LEDGER_DB_PATH` 须继续在启动环境中设置。

“检查连接”可查看本机服务状态及 Windows 网络类别；`outputs/check-ledger-connection.cmd` 提供更详细的不带令牌的只读诊断。详情见[连接排查与隐私说明](../CONNECTION-PRIVACY.md)。窗口不修改防火墙、不配置公网访问或开机启动。首次缺少虚拟环境时，先按下面步骤安装依赖；源码包用户可执行 `powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\ledger-desktop.ps1` 打开窗口。原 `start-ledger-server.ps1` 保留命令行模式。

### 手动安装与启动

安装 Python 3.12 后，在文件管理器打开本 `server` 目录，在地址栏输入 `powershell` 并回车，或在 PowerShell 中用 `Set-Location` 进入本目录。首次运行以下命令安装依赖并生成令牌：

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -c "import secrets; print(secrets.token_urlsafe(48))"
```

将最后一条命令生成的随机值设为 `LEDGER_API_TOKEN`；请自行保存，手机连接时需要同一个值。指定一个位于这台电脑本地磁盘的数据库位置：

```powershell
$env:LEDGER_API_TOKEN = "将上一步生成的随机值粘贴到这里"
$env:LEDGER_DB_PATH = Join-Path $env:LOCALAPPDATA "PrivateLedger\ledger.sqlite3"
.\.venv\Scripts\python.exe -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

打开 `http://127.0.0.1:8000/health` 应得到 `{"status":"ok","service":"private-ledger"}`。这一步只验证电脑本机，手机访问须按下一节绑定局域网地址。除健康检查外，所有数据接口都要求 `Authorization: Bearer <LEDGER_API_TOKEN>`。令牌须为 24～1024 个可打印 ASCII 字符，不含空格；否则服务会拒绝启动。

首次启动会自动创建数据库目录。上述位置通常是 `C:\Users\你的用户名\AppData\Local\PrivateLedger\ledger.sqlite3`，请保留此路径用于后续启动和备份。终端窗口需要保持运行；按 `Ctrl+C` 可停止服务。

环境变量只在当前 PowerShell 窗口中生效。下次开机或新开终端时，重新进入 `server` 目录，设置**同一个令牌和数据库路径**，再执行 `uvicorn` 命令。无需重新创建虚拟环境、安装依赖或生成令牌。当前版本尚未配置 Windows 开机自启动。

## 让手机连接

先完成本机 `/health` 检查，再按使用环境设置监听地址：

| 使用环境 | 后端监听地址 | 手机填写的服务器地址 |
| --- | --- | --- |
| 手机与电脑在同一可信 Wi-Fi | 电脑的局域网 IPv4，例如 `192.168.1.20` | `http://192.168.1.20:8000` |
| 外出，经私人 VPN 连接 | 电脑的 VPN IPv4 | `http://电脑VPN地址:8000` |
| 已配置 HTTPS 反向代理 | 按自己的代理配置监听 | HTTPS 根地址，例如 `https://ledger.example.com` |

可运行 `ipconfig` 查看当前连接使用的 Wi-Fi/以太网 IPv4。按 `Ctrl+C` 停止此前只监听本机的服务，将下面的示例地址替换为电脑实际地址后重新启动：

```powershell
.\.venv\Scripts\python.exe -m uvicorn app.main:app --host 192.168.1.20 --port 8000
```

此时 Windows 本机和手机都应通过 `http://192.168.1.20:8000/health` 检查连通性。确认可访问后，在手机应用中填写同一根地址和令牌。若 Windows 防火墙拦截连接，允许此服务的 TCP 8000 端口从相应可信局域网或 VPN 网络访问。

外出同步需要电脑和手机接入同一个**私有 VPN**，并把 `--host` 改成电脑的 VPN IPv4。手机支持 HTTP 私有 IPv4、VPN IPv4 和本机开发地址，公网服务须使用 HTTPS。不要把开发用 HTTP 端口直接映射到公网。电脑关机、休眠或断网时，手机保留已有数据和待同步修改；电脑恢复服务并且手机应用再次运行后继续同步。

数据库文件应保存在 Windows 本地磁盘。换一台手机时，连接原服务即可下载主账本；更换 Windows 主机则需要迁移数据库以及更新手机上的服务器地址。

## 主要接口

0.4.0 新增 `POST /api/v1/transactions`：手动记账幂等创建，客户端提供 UUID 操作ID、交易ID、金额整数分、收支方向和带时区日期，其余分类/商户/备注可选。所有接口继续需要原令牌。

`POST /api/v1/edits` 现在支持金额、日期、商户、说明和收支方向修正，保留版本冲突和退款关联保护；原始导入内容不随修正覆盖。

`GET /api/v1/imports/{preview_id}/rows?offset=0&limit=50` 可分页审核全部预览，返回重复标记，不返回原始附加字段；每页上限100，过期或已提交预览不能再次读取明细。用户确认前，预览不会写入正式流水。

### 钱迹导出 CSV 兼容（2026-10-28）

已适配含 ID、时间、账本、分类、二级分类、类型、金额、币种的钱迹 CSV。手机来源请选择“标准 CSV”。支持人民币 Spend 支出与 Income 收入，保留分类、二级分类、标签和备注；钱迹 ID 加来源前缀用于重复导入去重。账户、记账者、图片等附加列不保存。转账、其他币种、费用/优惠/报销/关联等尚未适配的语义会拒绝，不静默改变金额。

本次用户指定样本 1,946 笔已通过只读内存解析，逐笔核对金额、方向、分类、备注、ID 及去重稳定性；未写入正式账本。新增合成兼容与 API 去重用例后，73 项后端测试、10 个子测试通过。更新后需停止并重新启动电脑端服务；手机无需更新 APK。

| 接口 | 用途 |
| --- | --- |
| `GET /api/v1/sync?since=0` | 全量或增量取得交易、修订号、设置 |
| `POST /api/v1/edits` | 带操作 ID 和预期版本的离线修改；版本冲突返回 409 |
| `GET/PATCH /api/v1/settings` | 查看或修改 `exclude_red_packets` |
| `GET/POST /api/v1/rules`、`DELETE /api/v1/rules/{id}` | 查看、新建、删除自动分类规则 |
| `POST /api/v1/imports/preview` | 上传账单，预览新增及重复记录 |
| `POST /api/v1/imports/{preview_id}/commit` | 确认入账，重复请求安全 |
| `GET /api/v1/reports/month?year=2026&month=9` | 按实际消费口径获取月报 |
| `GET /api/v1/reports/year?year=2026` | 同一读取快照的年度汇总、分类合计和 12 个月报 |
| `GET /api/v1/export.csv?year=2026&month=9&redact=true` | 导出指定月份的 CSV，或省略年月导出全部 |

`/api/v1/imports/preview` 使用 multipart 表单，字段为 `source`（`alipay`、`wechat` 或 `generic`）和 `file`，单文件最大 10 MiB。可选字段 `column_mapping` 是 JSON 对象，例如 `{"occurred_at":"交易日期","amount":"金额","direction":"收支"}`，用于指定 CSV 表头。通用 CSV 可用的字段示例：`occurred_at,amount,direction,kind,merchant,description,external_id,category,tags,note`。金额是元，`direction` 为 `expense` 或 `income`。支付宝、微信的真实脱敏账单样本尚未拿到；对应解析逻辑目前只适合作为待校验的适配起点，不应直接视为已适配所有官方导出格式。

新建规则的 JSON 示例：

```json
{
  "enabled": true,
  "priority": 10,
  "conditions": {"merchant_contains": "咖啡", "direction": "expense"},
  "actions": {"category": "餐饮", "tags": ["咖啡"]}
}
```

规则条件采用“全部匹配”，关键字不区分大小写；`priority` 越小越优先，不同操作字段分别取第一个命中的规则。规则可以设置 `category`、`tags` 和 `excluded`。规则只应用于**之后预览的导入**；创建或删除规则不会改写既有交易，人工修改过的记录保持原样。导入预览会保留当时的规则结果，随后确认入账时使用该预览结果。未提交预览 24 小时后失效，在下次启动、预览或提交时清理；提交后清空预览流水副本，保留提交结果支持幂等重试。

月报中的“实际消费”会把**已关联**退款冲减原购买月份；尚未关联的退款单列，便于人工检查。超过原购买金额的部分不再继续冲减，并在 `over_refund_cents` 提示核对。收发红包默认都不计入消费或收入；设置关闭排除后，未被人工或规则覆盖的红包会计入。转账默认排除，人工或规则确认后可计入。导出的 CSV 按流水发生日期过滤，包含分类和标签；`redact=true` 会移除商户、描述、交易号、标签和备注，将类别替换为文件内一致的别名，并临时映射流水和退款关联 ID。日期、金额等仍保留，不能视为匿名；多次脱敏导出不能按 ID 或类别别名关联。导出文本对电子表格公式前缀做了转义。

## 备份与测试

建议定期备份主数据库。最简单的方法是先停止服务，再复制 `LEDGER_DB_PATH` 指向的 `.sqlite3` 文件，之后重新启动；避免在写入过程中只复制数据库主文件而漏掉 WAL 文件。备份文件同样含有敏感账单数据。

开发时安装 `requirements-dev.txt`，然后运行：

```powershell
.\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
.\.venv\Scripts\python.exe -m pytest -q
```

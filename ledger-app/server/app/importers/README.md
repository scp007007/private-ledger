# Generic CSV import template

`generic_template.csv` is a blank template. Fill one transaction per row. Keep the
header names unchanged, or supply a `column_mapping` to `parse_bill` later.

Required columns are `occurred_at`, `amount`, and `direction`. `kind` defaults to
`payment` for a row with a description. The accepted directions are `expense`
and `income`; kinds are `payment`, `refund`, `transfer`, `red_packet`, and `other`.
Use positive amounts in yuan with no more than two decimal places, for example
`23.50`. A time such as `2026-09-01 12:00:00` is interpreted in China Standard
Time; an ISO 8601 offset or `Z` (UTC) may be included explicitly. All stored
timestamps are converted to China Standard Time (`+08:00`) so monthly reports
use local calendar months. The remaining columns are
optional. `external_id` should be a stable transaction identifier if available.
Separate multiple tags with semicolons.

Transfers and red packets are initially excluded from reports but remain in
the ledger for review. The user may include them manually or through a rule.
For rows with a transaction ID, repeated payment exports use the same key even
if the export time or amount changes. Refund rows additionally use event time
and amount because one trade ID may be shared by several partial refunds. A
corrected refund with the same ID but changed time or amount may therefore
appear as a new transaction. This compromise needs checking against actual
redacted exports before relying on automatic imports.

The importer also recognizes a provisional set of common Chinese header names
and accepts UTF-8, UTF-8 with BOM, and GB18030 CSV. Those aliases have only
been tested with synthetic examples. Real Alipay and WeChat exports have not
yet been provided, so their exact layouts and semantics remain unverified.

An optional mapping lets a future UI bind unfamiliar column names without
changing the parser, for example:

```python
parse_bill(
    "generic", "my-bill.csv", content,
    column_mapping={"occurred_at": "日期时间", "amount": "实付", "direction": "方向"},
)
```

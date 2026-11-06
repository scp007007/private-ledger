"""Import CSV account statements into normalized, reviewable transactions.

The Chinese header aliases are provisional. They are intentionally covered with
synthetic fixtures until redacted Alipay and WeChat exports are available.
"""

from __future__ import annotations

import csv
import hashlib
import io
import json
import re
import unicodedata
import zipfile
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from pathlib import PurePosixPath
from typing import Mapping

__all__ = ["BillImportError", "GENERIC_CSV_COLUMNS", "parse_bill"]

MAX_FILE_BYTES = 25 * 1024 * 1024
MAX_ARCHIVE_ENTRIES = 100
LOCAL_TIMEZONE = timezone(timedelta(hours=8))
GENERIC_CSV_COLUMNS = (
    "occurred_at", "amount", "direction", "kind", "merchant", "description",
    "external_id", "category", "tags", "note",
)


class BillImportError(ValueError):
    """A bill cannot be safely or unambiguously imported."""


def _header_key(value: str) -> str:
    value = unicodedata.normalize("NFKC", value).strip().lower()
    return re.sub(r"[\s_\-/:：.()\[\]【】·¥￥]+", "", value)


_ALIASES: dict[str, tuple[str, ...]] = {
    "occurred_at": (
        "occurred_at", "交易时间", "付款时间", "支付时间", "交易创建时间",
        "创建时间", "日期时间", "日期", "时间", "date", "datetime", "timestamp",
    ),
    "amount": (
        "amount", "amount_yuan", "实付金额(元)", "实付金额", "金额(元)",
        "交易金额(元)", "收支金额(元)", "订单金额(元)", "金额",
        "交易金额", "收支金额", "money", "price",
    ),
    "direction": (
        "direction", "收/支", "收支", "收支方向", "资金方向", "收入支出",
        "income_expense", "income/expense", "flow",
    ),
    "kind": ("kind", "交易类型", "交易分类", "收支类型", "类型", "transaction_type"),
    "merchant": (
        "merchant", "交易对方", "收/付款方", "收付款方", "对方", "商户",
        "商家", "商户名称", "payee", "counterparty",
    ),
    "description": (
        "description", "商品", "商品名称", "商品说明", "交易内容", "交易名称",
        "商品详情", "内容", "title", "details",
    ),
    "external_id": (
        "external_id", "交易单号", "支付宝交易号", "微信支付单号", "交易号",
        "商户单号", "商家订单号", "商户订单号", "订单号", "transaction_id", "trade_no",
    ),
    "category": ("category", "消费分类", "自定义分类", "分类", "类别"),
    "tags": ("tags", "标签"),
    "note": ("note", "备注", "memo", "comment"),
    "status": ("status", "当前状态", "交易状态", "订单状态", "资金状态"),
}
_ALIAS_KEYS = {
    field: tuple(_header_key(alias) for alias in aliases)
    for field, aliases in _ALIASES.items()
}


def _extract_csv(filename: str, content: bytes) -> bytes:
    if not content:
        raise BillImportError("账单文件为空。")
    if len(content) > MAX_FILE_BYTES:
        raise BillImportError("账单文件超过 25 MiB 限制，请分批导出。")

    suffix = PurePosixPath(filename.replace("\\", "/")).suffix.lower()
    if suffix == ".csv":
        if content.startswith(b"PK\x03\x04"):
            raise BillImportError("文件名为 CSV，但内容是 ZIP，请使用 .zip 文件名。")
        return content
    if suffix != ".zip":
        raise BillImportError("当前仅支持 CSV 或包含一个 CSV 的 ZIP；Excel 文件暂不支持。")

    try:
        with zipfile.ZipFile(io.BytesIO(content)) as archive:
            entries = archive.infolist()
            if len(entries) > MAX_ARCHIVE_ENTRIES:
                raise BillImportError("ZIP 文件条目过多，请只保留账单 CSV。")
            candidates = []
            for entry in entries:
                normalized_name = entry.filename.replace("\\", "/")
                path = PurePosixPath(normalized_name)
                if (
                    normalized_name.startswith("/")
                    or re.match(r"^[a-zA-Z]:", normalized_name)
                    or ".." in path.parts
                ):
                    raise BillImportError("ZIP 包含不安全的文件路径。")
                if entry.is_dir():
                    continue
                if entry.file_size > MAX_FILE_BYTES:
                    raise BillImportError("ZIP 内的 CSV 超过 25 MiB 限制。")
                if path.suffix.lower() == ".csv":
                    candidates.append(entry)
            if len(candidates) != 1:
                raise BillImportError("ZIP 必须恰好包含一个 CSV 账单文件。")
            with archive.open(candidates[0]) as stream:
                data = stream.read(MAX_FILE_BYTES + 1)
            if len(data) > MAX_FILE_BYTES:
                raise BillImportError("ZIP 内的 CSV 超过 25 MiB 限制。")
            return data
    except (zipfile.BadZipFile, RuntimeError, OSError, EOFError) as exc:
        raise BillImportError("ZIP 文件损坏或受密码保护，无法读取 CSV。") from exc


def _decode_csv(content: bytes) -> str:
    if b"\x00" in content[:4096]:
        raise BillImportError("账单包含二进制内容；当前仅支持 CSV 文本。")
    for encoding in ("utf-8-sig", "gb18030"):
        try:
            return content.decode(encoding)
        except UnicodeDecodeError:
            continue
    raise BillImportError("无法识别账单编码；请导出 UTF-8 或 GB18030 CSV。")


def _column_indices(
    headers: list[str], column_mapping: Mapping[str, str]
) -> dict[str, int]:
    normalized = [_header_key(header) for header in headers]
    found: dict[str, int] = {}
    for field, aliases in _ALIAS_KEYS.items():
        for alias in aliases:
            if alias in normalized:
                found[field] = normalized.index(alias)
                break
    for field, header in column_mapping.items():
        key = _header_key(header)
        if key in normalized:
            found[field] = normalized.index(key)
        else:
            found.pop(field, None)
    return found


def _find_header(
    text: str, column_mapping: Mapping[str, str]
) -> tuple[str, int, list[str], dict[str, int]]:
    best: tuple[int, str, int, list[str], dict[str, int]] | None = None
    best_partial: dict[str, int] = {}
    seen_header_keys: set[str] = set()
    for delimiter in (",", "\t", ";"):
        try:
            reader = csv.reader(io.StringIO(text, newline=""), delimiter=delimiter, strict=True)
            for row_index, row in enumerate(reader):
                if row_index >= 100:
                    break
                seen_header_keys.update(_header_key(item) for item in row)
                columns = _column_indices(row, column_mapping)
                if len(columns) > len(best_partial):
                    best_partial = columns
                if "occurred_at" not in columns or "amount" not in columns:
                    continue
                if "direction" not in columns and "kind" not in columns:
                    continue
                score = len(columns)
                if best is None or score > best[0]:
                    best = (score, delimiter, row_index, row, columns)
        except csv.Error as exc:
            raise BillImportError("CSV 引号或分隔符格式不正确。") from exc
    if best is None:
        missing_mapped = [
            field for field, header in column_mapping.items()
            if _header_key(header) not in seen_header_keys
        ]
        if missing_mapped:
            names = "、".join(missing_mapped)
            raise BillImportError(f"列映射指定的表头未在 CSV 中找到，请检查字段：{names}。")
        recognized = "、".join(sorted(best_partial)) or "无"
        raise BillImportError(
            "未找到包含交易时间、金额和收支方向或交易类型的表头；"
            f"当前识别到的字段：{recognized}。请检查列映射或提供 CSV 样本校准。"
        )
    _, delimiter, row_index, headers, columns = best
    missing_mapped = [
        field for field, header in column_mapping.items()
        if _header_key(header) not in {_header_key(item) for item in headers}
    ]
    if missing_mapped:
        names = "、".join(missing_mapped)
        raise BillImportError(f"列映射指定的表头未在 CSV 中找到，请检查字段：{names}。")
    return delimiter, row_index, headers, columns


def _get(row: list[str], columns: dict[str, int], field: str) -> str:
    position = columns.get(field)
    if position is None or position >= len(row):
        return ""
    return row[position].strip()


def _parse_datetime(value: str, row_number: int) -> str:
    if not value:
        raise BillImportError(f"第 {row_number} 行缺少交易时间。")
    normalized = unicodedata.normalize("NFKC", value).strip()
    normalized = normalized.replace("年", "-").replace("月", "-").replace("日", "")
    normalized = normalized.replace("/", "-")
    if normalized.endswith("Z"):
        normalized = normalized[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        parsed = None
        for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
            try:
                parsed = datetime.strptime(normalized, fmt)
                break
            except ValueError:
                pass
        if parsed is None:
            raise BillImportError(f"第 {row_number} 行交易时间无法识别，请检查日期格式。")
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=LOCAL_TIMEZONE)
    else:
        parsed = parsed.astimezone(LOCAL_TIMEZONE)
    return parsed.isoformat(timespec="microseconds" if parsed.microsecond else "seconds")


def _parse_amount(value: str, row_number: int) -> tuple[int, int]:
    if not value:
        raise BillImportError(f"第 {row_number} 行缺少金额。")
    normalized = unicodedata.normalize("NFKC", value).strip()
    negative_parens = normalized.startswith("(") and normalized.endswith(")")
    if negative_parens:
        normalized = normalized[1:-1]
    normalized = normalized.replace("人民币", "")
    normalized = re.sub(r"(?i)(?:rmb|cny)", "", normalized)
    normalized = normalized.replace("¥", "").replace("￥", "").replace("元", "")
    normalized = normalized.replace(",", "").replace(" ", "").strip()
    try:
        decimal = Decimal(normalized)
    except InvalidOperation as exc:
        raise BillImportError(f"第 {row_number} 行金额无法识别，请检查金额格式。") from exc
    if not decimal.is_finite() or decimal.as_tuple().exponent < -2:
        raise BillImportError(f"第 {row_number} 行金额必须精确到分。")
    if negative_parens:
        decimal = -abs(decimal)
    cents = decimal * 100
    if cents == 0:
        raise BillImportError(f"第 {row_number} 行金额必须大于零。")
    return abs(int(cents)), -1 if decimal < 0 else 1


def _classify_kind(value: str, description: str) -> str:
    marker = unicodedata.normalize("NFKC", value).strip().lower()
    if marker in ("payment", "refund", "transfer", "red_packet", "other"):
        return marker
    if "红包" in marker or "red packet" in marker or "redpacket" in marker:
        return "red_packet"
    if "退款" in marker or "退货" in marker:
        return "refund"
    if "转账" in marker or "转入" in marker or "转出" in marker or "transfer" in marker:
        return "transfer"
    if not marker and (description.startswith("微信红包") or description.startswith("支付宝红包")):
        return "red_packet"
    if not marker and description.startswith("退款"):
        return "refund"
    return "payment" if marker or description else "other"


def _classify_direction(
    value: str, kind_text: str, kind: str, amount_sign: int, row_number: int
) -> tuple[str, bool]:
    marker = unicodedata.normalize("NFKC", value).strip().lower()
    if marker in ("expense", "out", "debit", "支出", "支", "付款", "付出"):
        return "expense", False
    if marker in ("income", "in", "credit", "收入", "收", "收款"):
        return "income", False
    no_flow = marker in ("不计收支", "不计入收支", "中性交易", "neutral")
    if marker and not no_flow and marker not in ("/", "-", "--"):
        raise BillImportError(f"第 {row_number} 行收支方向无法识别，请检查收支方向列。")
    type_marker = unicodedata.normalize("NFKC", kind_text).strip().lower()
    if any(term in type_marker for term in ("收到", "收款", "转入", "入账", "收红包")):
        return "income", no_flow
    if any(term in type_marker for term in ("付款", "支出", "转出", "发红包", "消费", "支付", "购买")):
        return "expense", no_flow
    if kind == "refund":
        return "income", no_flow
    if amount_sign < 0:
        return "expense", no_flow
    if no_flow and kind in ("transfer", "red_packet"):
        return "expense", True
    raise BillImportError(
        f"第 {row_number} 行无法判断收支方向；请在账单中提供“收/支”或 direction 列。"
    )


def _is_footer(row: list[str]) -> bool:
    values = [item.strip() for item in row if item.strip()]
    if not values:
        return True
    if len(values) == 1:
        value = values[0]
        return bool(re.match(r"^(?:[-=]{3,}|共\s*\d+\s*笔|合计|总计|收入合计|支出合计)", value))
    return False


def _dedupe_key(transaction: dict) -> str:
    if transaction["external_id"]:
        identity = [
            transaction["source"], "id", transaction["external_id"],
            transaction["kind"],
        ]
        if transaction["kind"] == "refund":
            # Some sources can reference the original trade ID in every partial
            # refund. Their event time and amount distinguish refund legs until
            # an actual export provides a separate refund identifier.
            identity.extend((transaction["occurred_at"], transaction["amount_cents"]))
    else:
        identity = [
            transaction["source"], "fields", transaction["occurred_at"],
            transaction["amount_cents"], transaction["direction"],
            transaction["kind"], transaction["merchant"],
            transaction["description"],
        ]
    encoded = json.dumps(identity, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def _raw_row(row: list[str], columns: dict[str, int]) -> dict[str, str]:
    """Keep recognized accounting cells under fixed field names only.

    Unused export columns and user-supplied header names can contain account
    numbers or other private identifiers and are not needed by the ledger.
    """
    return {
        field: row[index] if index < len(row) else ""
        for field, index in columns.items()
    }


def _normalize_qianji_csv(text: str, source: str) -> str:
    """Adapt a recognized QianJi export; do not retain account/member columns."""
    reader = csv.DictReader(io.StringIO(text, newline=""), strict=True)
    headers = reader.fieldnames or []
    required = {"ID", "时间", "账本", "类型", "金额", "币种", "分类", "二级分类"}
    if not required.issubset(headers):
        return text
    if source != "generic":
        raise BillImportError("这是钱迹导出文件，请将账单来源选为“标准 CSV”后重新导入。")
    if len(set(headers)) != len(headers):
        raise BillImportError("钱迹 CSV 包含重复表头，无法安全导入。")
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=GENERIC_CSV_COLUMNS)
    writer.writeheader()
    for line, row in enumerate(reader, start=2):
        if None in row:
            raise BillImportError(f"第 {line} 行的列数多于表头，无法安全导入。")
        if (row.get("币种") or "").strip().upper() != "CNY":
            raise BillImportError(f"第 {line} 行不是人民币流水；当前不支持自动换算币种。")
        marker = (row.get("类型") or "").strip().lower()
        kinds = {"spend": ("expense", "payment"), "income": ("income", "other")}
        if marker not in kinds:
            raise BillImportError(f"第 {line} 行的钱迹交易类型尚不支持；当前支持 Spend 和 Income。")
        # These features have accounting semantics beyond a plain migration.
        if any((row.get(key) or "").strip() for key in ("手续费", "优惠券", "已报销", "关联账单")):
            raise BillImportError(f"第 {line} 行包含尚未适配的费用、报销或关联信息，请先核对。")
        identity = (row.get("ID") or "").strip()
        if not identity:
            raise BillImportError(f"第 {line} 行缺少钱迹 ID，无法可靠去重。")
        category = " / ".join((row.get(key) or "").strip() for key in ("分类", "二级分类") if (row.get(key) or "").strip())
        direction, kind = kinds[marker]
        writer.writerow({
            "occurred_at": row.get("时间"), "amount": row.get("金额"),
            "direction": direction, "kind": kind,
            "merchant": "", "description": category or "钱迹导入",
            "external_id": "qianji:" + identity, "category": category,
            "tags": row.get("标签") or "", "note": row.get("备注") or "",
        })
    return output.getvalue()


def parse_bill(
    source: str,
    filename: str,
    content: bytes,
    column_mapping: Mapping[str, str] | None = None,
) -> list[dict]:
    """Parse a CSV bill, retaining raw values only for recognized ledger fields.

    Amounts are positive integer cents; ``direction`` carries the sign. Dates
    without an offset use China Standard Time. The fallback duplicate key can
    merge indistinguishable rows without transaction IDs, so previews matter.
    ``column_mapping`` maps canonical field names to exact CSV header names.
    """
    if source not in ("alipay", "wechat", "generic"):
        raise BillImportError("账单来源必须是 alipay、wechat 或 generic。")
    if not isinstance(content, bytes):
        raise BillImportError("账单内容必须是文件字节。")
    mapping = {} if column_mapping is None else column_mapping
    if not isinstance(mapping, Mapping):
        raise BillImportError("列映射必须是字段名到 CSV 表头名的映射。")
    for field, header in mapping.items():
        if field not in _ALIASES or not isinstance(header, str) or not header.strip():
            raise BillImportError("列映射字段无效，请使用支持的账本字段名和非空表头名。")
    if len({_header_key(value) for value in mapping.values()}) != len(mapping):
        raise BillImportError("一个 CSV 表头不能同时映射到多个字段。")
    text = _decode_csv(_extract_csv(filename, content))
    try:
        text = _normalize_qianji_csv(text, source)
    except csv.Error as exc:
        raise BillImportError("CSV 引号或分隔符格式不正确。") from exc
    delimiter, header_index, headers, columns = _find_header(text, mapping)
    parsed: list[dict] = []
    try:
        reader = csv.reader(io.StringIO(text, newline=""), delimiter=delimiter, strict=True)
        for row_index, row in enumerate(reader):
            if row_index <= header_index:
                continue
            row_number = reader.line_num
            if _is_footer(row):
                continue
            if [_header_key(item) for item in row] == [_header_key(item) for item in headers]:
                continue
            if len(row) > len(headers):
                raise BillImportError(f"第 {row_number} 行的列数多于表头，无法安全导入。")
            raw = _raw_row(row, columns)
            amount_cents, amount_sign = _parse_amount(_get(row, columns, "amount"), row_number)
            occurred_at = _parse_datetime(_get(row, columns, "occurred_at"), row_number)
            kind_text = _get(row, columns, "kind")
            description = _get(row, columns, "description") or kind_text
            kind = _classify_kind(kind_text, description)
            direction, no_flow = _classify_direction(
                _get(row, columns, "direction"), kind_text, kind, amount_sign, row_number
            )
            status = _get(row, columns, "status")
            closed = any(term in status for term in ("交易关闭", "订单关闭", "已关闭", "交易失败", "支付失败", "已撤销"))
            exclusion_reason = (
                "closed_or_failed" if closed else
                "default_red_packet" if kind == "red_packet" else
                "default_transfer" if kind == "transfer" else
                "source_no_flow" if no_flow else None
            )
            tags_raw = _get(row, columns, "tags")
            transaction = {
                "source": source,
                "external_id": _get(row, columns, "external_id") or None,
                "occurred_at": occurred_at,
                "amount_cents": amount_cents,
                "direction": direction,
                "kind": kind,
                "merchant": _get(row, columns, "merchant"),
                "description": description,
                "category": _get(row, columns, "category") or None,
                "tags": [tag.strip() for tag in re.split(r"[;,|，；]", tags_raw) if tag.strip()],
                "note": _get(row, columns, "note"),
                "excluded": exclusion_reason is not None,
                "exclusion_reason": exclusion_reason,
                "refund_of_id": None,
                "raw_data": raw,
            }
            transaction["dedupe_key"] = _dedupe_key(transaction)
            parsed.append(transaction)
    except csv.Error as exc:
        raise BillImportError("CSV 引号或分隔符格式不正确。") from exc
    if not parsed:
        raise BillImportError("账单中未找到可导入的交易记录。")
    return parsed

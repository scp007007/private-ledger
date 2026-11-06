"""Synthetic importer fixtures; real platform exports are not yet available."""

from __future__ import annotations

import io
import sys
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.importers import BillImportError, parse_bill


class BillImporterTests(unittest.TestCase):
    def test_generic_payment_refund_and_stable_identity(self) -> None:
        csv_bytes = (
            "occurred_at,amount,direction,kind,merchant,description,external_id,category,tags,note\n"
            "2026-09-01 12:00:00,100.00,expense,payment,商店,购物,pay-1,购物,日常;家庭,首笔\n"
            "2026-10-01 12:00:00,40.00,income,refund,商店,部分退款,refund-1,,,\n"
        ).encode("utf-8")
        rows = parse_bill("generic", "bill.csv", csv_bytes)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["amount_cents"], 10000)
        self.assertEqual(rows[0]["occurred_at"], "2026-09-01T12:00:00+08:00")
        self.assertEqual(rows[0]["category"], "购物")
        self.assertEqual(rows[0]["tags"], ["日常", "家庭"])
        self.assertEqual(rows[0]["raw_data"]["description"], "购物")
        self.assertEqual(rows[1]["kind"], "refund")
        self.assertEqual(rows[1]["direction"], "income")
        self.assertEqual(rows[0]["dedupe_key"], parse_bill("generic", "same.csv", csv_bytes)[0]["dedupe_key"])
        self.assertNotEqual(rows[0]["dedupe_key"], rows[1]["dedupe_key"])

    def test_utf8_bom_preamble_chinese_headers_and_exclusions(self) -> None:
        synthetic = (
            "微信支付账单明细\n"
            "微信昵称：已脱敏\n"
            "共 3 笔记录\n"
            "交易时间,交易类型,交易对方,商品,收/支,金额(元),当前状态,交易单号,备注\n"
            "2026-09-02 10:00:00,商户消费,小店,午餐,支出,23.50,支付成功,wx-1,\n"
            "2026-09-03 10:00:00,微信红包,朋友,红包,收入,5.00,已收款,wx-2,\n"
            "2026-09-04 10:00:00,转账,本人账户,转账,不计收支,100.00,转账成功,wx-3,\n"
            "共 3 笔\n"
        ).encode("utf-8-sig")
        rows = parse_bill("wechat", "wechat.csv", synthetic)
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[0]["description"], "午餐")
        self.assertEqual(rows[0]["amount_cents"], 2350)
        self.assertFalse(rows[0]["excluded"])
        self.assertEqual(rows[1]["kind"], "red_packet")
        self.assertEqual(rows[1]["exclusion_reason"], "default_red_packet")
        self.assertEqual(rows[2]["kind"], "transfer")
        self.assertEqual(rows[2]["exclusion_reason"], "default_transfer")

    def test_gb18030_alipay_like_headers_and_amount(self) -> None:
        synthetic = (
            "支付宝交易明细查询\n"
            "交易号,交易创建时间,付款时间,类型,交易对方,商品名称,金额（元）,收/支,交易状态\n"
            'ali-1,2026/09/01 09:00:00,2026/09/01 09:02:00,消费,店铺,电脑,"￥1,234.56",支出,交易成功\n'
            "ali-2,2026/09/01 11:00:00,2026/09/01 11:00:00,退款,店铺,退款,20.00,收入,退款成功\n"
        ).encode("gb18030")
        rows = parse_bill("alipay", "alipay.csv", synthetic)
        self.assertEqual(rows[0]["external_id"], "ali-1")
        self.assertEqual(rows[0]["occurred_at"], "2026-09-01T09:02:00+08:00")
        self.assertEqual(rows[0]["amount_cents"], 123456)
        self.assertEqual(rows[1]["kind"], "refund")

    def test_explicit_utc_time_is_stored_in_china_local_month(self) -> None:
        content = (
            "occurred_at,amount,direction,external_id\n"
            "2026-08-31T16:30:00Z,1.00,expense,utc-1\n"
            "2026-08-31T23:30:00+02:00,2.00,expense,offset-1\n"
        ).encode("utf-8")
        rows = parse_bill("generic", "timezones.csv", content)
        self.assertEqual(rows[0]["occurred_at"], "2026-09-01T00:30:00+08:00")
        self.assertEqual(rows[1]["occurred_at"], "2026-09-01T05:30:00+08:00")

    def test_zip_with_one_csv_and_rejects_unsafe_archive(self) -> None:
        bill = b"occurred_at,amount,direction\n2026-09-01,1.00,expense\n"
        archive_bytes = io.BytesIO()
        with zipfile.ZipFile(archive_bytes, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("exports/bill.csv", bill)
            archive.writestr("README.txt", "bill export")
        rows = parse_bill("generic", "bill.zip", archive_bytes.getvalue())
        self.assertEqual(rows[0]["amount_cents"], 100)

        unsafe_bytes = io.BytesIO()
        with zipfile.ZipFile(unsafe_bytes, "w") as archive:
            archive.writestr("../bill.csv", bill)
        with self.assertRaisesRegex(BillImportError, "不安全"):
            parse_bill("generic", "bill.zip", unsafe_bytes.getvalue())

        two_bytes = io.BytesIO()
        with zipfile.ZipFile(two_bytes, "w") as archive:
            archive.writestr("a.csv", bill)
            archive.writestr("b.csv", bill)
        with self.assertRaisesRegex(BillImportError, "恰好包含一个"):
            parse_bill("generic", "bill.zip", two_bytes.getvalue())

    def test_rejects_ambiguous_and_invalid_rows(self) -> None:
        cases = [
            ("bill.xlsx", b"anything", "仅支持 CSV"),
            ("bill.csv", b"date,amount\n2026-09-01,1.00\n", "未找到"),
            (
                "bill.csv",
                b"occurred_at,amount,direction\n2026-09-01,1.001,expense\n",
                "精确到分",
            ),
            (
                "bill.csv",
                b"occurred_at,amount,direction\n2026-09-01,0.00,expense\n",
                "金额必须大于零",
            ),
            (
                "bill.csv",
                b"occurred_at,amount,direction\n2026-09-01,1.00,unknown\n",
                "收支方向无法识别",
            ),
            (
                "bill.csv",
                b"occurred_at,amount,direction\n2026-99-01,1.00,expense\n",
                "交易时间无法识别",
            ),
        ]
        for filename, content, expected in cases:
            with self.subTest(filename=filename, content=content):
                with self.assertRaisesRegex(BillImportError, expected):
                    parse_bill("generic", filename, content)

    def test_unclosed_quote_fails_instead_of_merging_next_transaction(self) -> None:
        malformed = (
            'occurred_at,amount,direction,description\n'
            '2026-09-01,1.00,expense,"unclosed description\n'
            '2026-09-02,2.00,expense,second transaction\n'
        ).encode("utf-8")
        with self.assertRaisesRegex(BillImportError, "CSV 引号或分隔符格式不正确"):
            parse_bill("generic", "malformed.csv", malformed)

    def test_without_transaction_id_uses_normalized_fingerprint(self) -> None:
        first = (
            "occurred_at;amount;direction;merchant;description\n"
            "2026-09-01 12:00:00;1.00;expense;店铺;水\n"
        ).encode("utf-8")
        second = (
            "时间,金额,收/支,交易对方,商品\n"
            "2026-09-01 12:00:00,1.00,支出,店铺,水\n"
        ).encode("utf-8")
        one = parse_bill("generic", "a.csv", first)[0]
        two = parse_bill("generic", "b.csv", second)[0]
        self.assertIsNone(one["external_id"])
        self.assertEqual(one["dedupe_key"], two["dedupe_key"])

    def test_custom_column_mapping_and_missing_column_diagnostic(self) -> None:
        content = (
            "账单日期,实付款,出入方向,对方昵称,消费说明\n"
            "2026-09-01 12:00:00,12.34,expense,店铺,水\n"
        ).encode("utf-8")
        mapping = {
            "occurred_at": "账单日期",
            "amount": "实付款",
            "direction": "出入方向",
            "merchant": "对方昵称",
            "description": "消费说明",
        }
        row = parse_bill("generic", "custom.csv", content, column_mapping=mapping)[0]
        self.assertEqual(row["amount_cents"], 1234)
        self.assertEqual(row["merchant"], "店铺")

        with self.assertRaisesRegex(BillImportError, "列映射指定的表头未在 CSV 中找到，请检查字段：note"):
            parse_bill(
                "generic", "custom.csv", content,
                column_mapping={**mapping, "note": "未存在字段"},
            )

    def test_transaction_id_dedupes_reexports_but_keeps_partial_refunds(self) -> None:
        bill = (
            "occurred_at,amount,direction,kind,external_id\n"
            "2026-09-01 12:00:00,100.00,expense,payment,shared-1\n"
            "2026-10-01 12:00:00,20.00,income,refund,shared-1\n"
            "2026-10-02 12:00:00,20.00,income,refund,shared-1\n"
        ).encode("utf-8")
        rows = parse_bill("generic", "bill.csv", bill)
        corrected_payment = (
            "occurred_at,amount,direction,kind,external_id\n"
            "2026-09-02 13:00:00,99.00,expense,payment,shared-1\n"
        ).encode("utf-8")
        corrected = parse_bill("generic", "bill.csv", corrected_payment)[0]
        self.assertEqual(rows[0]["dedupe_key"], corrected["dedupe_key"])
        self.assertNotEqual(rows[0]["dedupe_key"], rows[1]["dedupe_key"])
        self.assertNotEqual(rows[1]["dedupe_key"], rows[2]["dedupe_key"])


if __name__ == "__main__":
    unittest.main()

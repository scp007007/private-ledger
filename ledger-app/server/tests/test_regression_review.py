"""Additional accounting and import concurrency checks from the UI review.

These exercise HTTP contracts with synthetic data, not emulator file pickers.
"""

from __future__ import annotations

import csv
import io

import pytest

from test_api import CSV_HEADER, HEADER, api, edit, import_csv, transactions


def preview(client, *lines):
    response = client.post(
        "/api/v1/imports/preview",
        headers=HEADER,
        data={"source": "generic"},
        files={"file": ("review.csv", ("\n".join((CSV_HEADER, *lines)) + "\n").encode(), "text/csv")},
    )
    assert response.status_code == 200, response.text
    return response.json()


def commit(client, draft):
    return client.post(f"/api/v1/imports/{draft['preview_id']}/commit", headers=HEADER)


def report(client, year, month):
    response = client.get("/api/v1/reports/month", headers=HEADER, params={"year": year, "month": month})
    assert response.status_code == 200, response.text
    return response.json()


def csv_rows(response):
    assert response.status_code == 200, response.text
    assert response.content.startswith(b"\xef\xbb\xbf")
    return list(csv.DictReader(io.StringIO(response.text.lstrip("\ufeff"))))


def test_multiple_cross_year_refunds_cap_once_and_exclusion_recalculates(api):
    client, _ = api
    import_csv(
        client,
        "2025-12-30 12:00:00,100.00,expense,payment,Shop,Purchase,purchase",
        "2026-01-01 12:00:00,60.00,income,refund,Shop,First refund,refund-1",
        "2026-02-01 12:00:00,50.00,income,refund,Shop,Second refund,refund-2",
        "2025-12-31 12:00:00,20.00,expense,payment,Restaurant,Lunch,lunch",
    )
    rows = {row["external_id"]: row for row in transactions(client)["transactions"]}
    assert edit(client, rows["purchase"], {"category": "Shopping"}).status_code == 200
    assert edit(client, rows["lunch"], {"category": "Meals"}).status_code == 200
    for key in ("refund-1", "refund-2"):
        response = edit(client, rows[key], {"refund_of_id": rows["purchase"]["id"]})
        assert response.status_code == 200, response.text
        rows[key] = response.json()["transaction"]

    december = report(client, 2025, 12)
    assert december["gross_consumption_cents"] == 12000
    assert december["applied_refunds_cents"] == 10000
    assert december["over_refund_cents"] == 1000
    assert december["total_actual_consumption_cents"] == 2000
    assert {item["category"]: item["amount_cents"] for item in december["category_totals"]} == {"Shopping": 0, "Meals": 2000}
    for month in (1, 2):
        refunded_month = report(client, 2026, month)
        assert refunded_month["total_income_cents"] == 0
        assert refunded_month["total_actual_consumption_cents"] == 0
        assert refunded_month["unlinked_refunds_count"] == 0

    assert edit(client, rows["refund-2"], {"excluded": True}).status_code == 200
    revised = report(client, 2025, 12)
    assert revised["applied_refunds_cents"] == 6000
    assert revised["total_actual_consumption_cents"] == 6000
    assert revised["over_refund_cents"] == 0


def test_duplicate_rows_and_overlapping_previews_commit_only_once(api):
    client, _ = api
    line = "2026-10-01 12:00:00,20.00,expense,payment,Shop,Item,pay-1"
    first = preview(client, line, line)
    second = preview(client, line)
    assert first["new_count"] == 1
    assert first["duplicate_count"] == 1
    assert second["new_count"] == 1
    one = commit(client, first)
    assert one.status_code == 200, one.text
    assert one.json()["imported"] == 1
    assert one.json()["duplicate"] == 1
    two = commit(client, second)
    assert two.status_code == 200, two.text
    assert two.json()["imported"] == 0
    assert two.json()["duplicate"] == 1
    assert commit(client, first).json() == one.json()
    assert len(transactions(client)["transactions"]) == 1
    assert transactions(client)["revision"] == 1


def test_redacted_csv_retains_accounting_fields_but_removes_private_text(api):
    client, _ = api
    import_csv(
        client,
        "2026-09-01 12:00:00,12.34,expense,payment,Private merchant,Private product,secret-id",
        "2026-10-01 12:00:00,1.00,income,refund,Private merchant,Private refund,refund-id",
    )
    rows = {row["external_id"]: row for row in transactions(client)["transactions"]}
    edited = edit(client, rows["secret-id"], {
        "category": "Shopping", "tags": ["private-person"], "note": "private-address", "excluded": True,
    })
    assert edited.status_code == 200, edited.text
    assert edit(client, rows["refund-id"], {"refund_of_id": rows["secret-id"]["id"]}).status_code == 200
    exported = csv_rows(client.get("/api/v1/export.csv?year=2026&redact=true", headers=HEADER))
    assert len(exported) == 2
    for row in exported:
        assert all(row[field] == "" for field in ("external_id", "merchant", "description", "tags", "note"))
    assert exported[0]["amount_cents"] == "1234"
    assert exported[0]["direction"] == "expense"
    assert exported[0]["category"] == "分类1"
    assert exported[0]["excluded"] == "True"
    assert exported[1]["refund_of_id"] == exported[0]["id"]
    assert len(csv_rows(client.get("/api/v1/export.csv?year=2026&month=9", headers=HEADER))) == 1


def test_csv_escapes_private_editable_formula_fields(api):
    client, _ = api
    import_csv(client, "2026-10-01 12:00:00,1.00,expense,payment,Shop,Item,pay-1")
    row = transactions(client)["transactions"][0]
    assert edit(client, row, {"category": " =SUM(1)", "tags": ["@SUM(1)"], "note": "\tformula"}).status_code == 200
    output = csv_rows(client.get("/api/v1/export.csv?year=2026&month=10", headers=HEADER))[0]
    assert output["category"] == "' =SUM(1)"
    assert output["tags"] == "'@SUM(1)"
    assert output["note"] == "'\tformula"


@pytest.mark.parametrize("initial_policy", [True, False])
def test_preview_commits_red_packets_under_current_default_policy(api, initial_policy):
    client, _ = api
    assert client.patch("/api/v1/settings", headers=HEADER, json={"exclude_red_packets": initial_policy}).status_code == 200
    draft = preview(
        client,
        "2026-10-01 12:00:00,20.00,expense,red_packet,Friend,Gift,red-1",
        "2026-10-01 13:00:00,5.00,income,red_packet,Friend,Gift,red-2",
    )
    assert all(row["excluded"] is initial_policy for row in draft["rows"])
    new_policy = not initial_policy
    updated = client.patch("/api/v1/settings", headers=HEADER, json={"exclude_red_packets": new_policy})
    assert updated.status_code == 200, updated.text
    response = commit(client, draft)
    assert response.status_code == 200, response.text
    snapshot = transactions(client)
    assert snapshot["settings"]["exclude_red_packets"] is new_policy
    assert all(row["excluded"] is new_policy for row in snapshot["transactions"])
    assert all(row["exclusion_reason"] == ("default_red_packet" if new_policy else None) for row in snapshot["transactions"])
    october = report(client, 2026, 10)
    assert october["total_actual_consumption_cents"] == (0 if new_policy else 2000)
    assert october["total_income_cents"] == (0 if new_policy else 500)
    assert commit(client, draft).json() == response.json()
    assert transactions(client)["revision"] == snapshot["revision"]


@pytest.mark.parametrize("rule_excluded", [True, False])
def test_stale_preview_retains_explicit_red_packet_rule_decisions(api, rule_excluded):
    client, _ = api
    assert client.patch("/api/v1/settings", headers=HEADER, json={"exclude_red_packets": rule_excluded}).status_code == 200
    created = client.post(
        "/api/v1/rules", headers=HEADER,
        json={"conditions": {"kind": "red_packet"}, "actions": {"excluded": rule_excluded}},
    )
    assert created.status_code == 200, created.text
    draft = preview(client, "2026-10-01 12:00:00,20.00,expense,red_packet,Friend,Gift,red-rule")
    assert draft["rows"][0]["excluded"] is rule_excluded
    assert client.patch("/api/v1/settings", headers=HEADER, json={"exclude_red_packets": not rule_excluded}).status_code == 200
    response = commit(client, draft)
    assert response.status_code == 200, response.text
    row = transactions(client)["transactions"][0]
    assert row["excluded"] is rule_excluded
    assert (row["exclusion_reason"] or "").startswith("rule:") is rule_excluded
    assert report(client, 2026, 10)["total_actual_consumption_cents"] == (0 if rule_excluded else 2000)


def test_stale_preview_preserves_failed_red_packet_exclusion(api):
    client, _ = api
    payload = (
        CSV_HEADER + ",status\n"
        "2026-10-01 12:00:00,20.00,expense,red_packet,Friend,Gift,red-failed,支付失败\n"
    ).encode("utf-8")
    response = client.post(
        "/api/v1/imports/preview", headers=HEADER,
        data={"source": "generic"}, files={"file": ("failed.csv", payload, "text/csv")},
    )
    assert response.status_code == 200, response.text
    draft = response.json()
    assert draft["rows"][0]["exclusion_reason"] == "closed_or_failed"
    assert client.patch("/api/v1/settings", headers=HEADER, json={"exclude_red_packets": False}).status_code == 200
    committed = commit(client, draft)
    assert committed.status_code == 200, committed.text
    row = transactions(client)["transactions"][0]
    assert row["excluded"] is True
    assert row["exclusion_reason"] == "closed_or_failed"
    assert report(client, 2026, 10)["total_actual_consumption_cents"] == 0


def test_year_report_sums_months_and_attributes_next_year_refund_to_purchase(api):
    client, _ = api
    import_csv(
        client,
        "2026-01-01 12:00:00,100.00,expense,payment,Shop,Purchase,purchase",
        "2026-12-01 12:00:00,50.00,expense,payment,Restaurant,Meal,meal",
        "2027-01-01 12:00:00,40.00,income,refund,Shop,Refund,refund",
        "2026-01-01 13:00:00,200.00,income,other,Employer,Salary,salary",
        "2026-12-02 12:00:00,5.00,income,refund,Shop,Unlinked refund,unlinked",
    )
    rows = {row["external_id"]: row for row in transactions(client)["transactions"]}
    assert edit(client, rows["refund"], {"refund_of_id": rows["purchase"]["id"]}).status_code == 200
    response = client.get("/api/v1/reports/year?year=2026", headers=HEADER)
    assert response.status_code == 200, response.text
    annual = response.json()
    assert annual["year"] == 2026
    assert annual["total_actual_consumption_cents"] == 11000
    assert annual["total_income_cents"] == 20000
    assert annual["gross_consumption_cents"] == 15000
    assert annual["applied_refunds_cents"] == 4000
    assert annual["over_refund_cents"] == 0
    assert annual["unlinked_refunds_count"] == 1
    assert annual["unlinked_refunds_cents"] == 500
    assert annual["category_totals"] == [{"category": "未分类", "amount_cents": 11000}]
    assert [monthly["month"] for monthly in annual["months"]] == list(range(1, 13))
    assert {monthly["revision"] for monthly in annual["months"]} == {annual["revision"]}
    assert annual["months"][0] == report(client, 2026, 1)
    assert annual["months"][11] == report(client, 2026, 12)
    assert annual["total_actual_consumption_cents"] == sum(item["total_actual_consumption_cents"] for item in annual["months"])
    assert client.get("/api/v1/reports/year?year=2027", headers=HEADER).json()["total_income_cents"] == 0


def test_year_report_empty_ledger_authentication_and_year_bounds(api):
    client, _ = api
    assert client.get("/api/v1/reports/year?year=2026").status_code == 401
    for year in (0, 10000):
        assert client.get(f"/api/v1/reports/year?year={year}", headers=HEADER).status_code == 422
    response = client.get("/api/v1/reports/year?year=2026", headers=HEADER)
    assert response.status_code == 200, response.text
    annual = response.json()
    assert len(annual["months"]) == 12
    assert annual["total_actual_consumption_cents"] == 0
    assert annual["total_income_cents"] == 0
    assert annual["category_totals"] == []

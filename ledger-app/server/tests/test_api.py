from __future__ import annotations

import csv
import io
import json
import sqlite3
import uuid

import pytest
from fastapi.testclient import TestClient

from app.db import connect
from app.main import create_app


TOKEN = "test-token-with-more-than-24-characters"
HEADER = {"Authorization": f"Bearer {TOKEN}"}
CSV_HEADER = "occurred_at,amount,direction,kind,merchant,description,external_id"


@pytest.fixture
def api(tmp_path):
    database_path = tmp_path / "ledger.sqlite3"
    with TestClient(create_app(database_path=database_path, api_token=TOKEN)) as client:
        yield client, database_path


def import_csv(client: TestClient, *lines: str, source: str = "generic") -> dict:
    payload = ("\n".join((CSV_HEADER, *lines)) + "\n").encode("utf-8")
    preview = client.post(
        "/api/v1/imports/preview",
        headers=HEADER,
        data={"source": source},
        files={"file": ("bill.csv", payload, "text/csv")},
    )
    assert preview.status_code == 200, preview.text
    result = client.post(f"/api/v1/imports/{preview.json()['preview_id']}/commit", headers=HEADER)
    assert result.status_code == 200, result.text
    return {"preview": preview.json(), "commit": result.json()}


def edit(client: TestClient, transaction: dict, changes: dict, *, operation_id: str | None = None, expected_version: int | None = None):
    return client.post(
        "/api/v1/edits",
        headers=HEADER,
        json={
            "operation_id": operation_id or str(uuid.uuid4()),
            "transaction_id": transaction["id"],
            "expected_version": expected_version or transaction["version"],
            "changes": changes,
        },
    )


def transactions(client: TestClient, since: int = 0) -> dict:
    response = client.get("/api/v1/sync", headers=HEADER, params={"since": since})
    assert response.status_code == 200, response.text
    return response.json()


def test_auth_sync_and_import_idempotence(api):
    client, db_path = api
    assert client.get("/health").json() == {"status": "ok", "service": "private-ledger"}
    assert client.get("/api/v1/sync").status_code == 401
    assert client.get("/api/v1/sync", headers={"Authorization": "Bearer wrong"}).status_code == 401

    line = "2026-09-01 12:00:00,100.00,expense,payment,商店,购物,pay-1"
    first = import_csv(client, line)
    assert first["preview"]["new_count"] == 1
    assert first["commit"]["imported"] == 1
    snapshot = transactions(client)
    assert snapshot["revision"] == 1
    assert len(snapshot["transactions"]) == 1
    assert snapshot["transactions"][0]["amount_cents"] == 10000
    assert transactions(client, since=1)["transactions"] == []

    second = import_csv(client, line)
    assert second["preview"]["duplicate_count"] == 1
    assert second["commit"]["duplicate"] == 1
    assert transactions(client)["revision"] == 1
    with connect(db_path) as connection:
        raw = connection.execute("SELECT raw_json FROM transactions").fetchone()[0]
    assert json.loads(raw)["description"] == "购物"


def test_sync_ledger_identity_survives_restart_and_legacy_migration(tmp_path):
    database_path = tmp_path / "legacy.sqlite3"
    with sqlite3.connect(database_path) as connection:
        connection.execute(
            "CREATE TABLE ledger_meta (id INTEGER PRIMARY KEY, revision INTEGER NOT NULL, "
            "exclude_red_packets INTEGER NOT NULL)"
        )
        connection.execute(
            "INSERT INTO ledger_meta (id, revision, exclude_red_packets) VALUES (1, 7, 1)"
        )

    with TestClient(create_app(database_path=database_path, api_token=TOKEN)) as client:
        first = transactions(client)
        assert first["revision"] == 7
        identity = first["ledger_id"]
        uuid.UUID(identity)

    with TestClient(create_app(database_path=database_path, api_token=TOKEN)) as client:
        assert transactions(client)["ledger_id"] == identity

    with TestClient(create_app(database_path=tmp_path / "new.sqlite3", api_token=TOKEN)) as client:
        assert transactions(client)["ledger_id"] != identity


def test_offline_edit_is_idempotent_and_version_conflict_is_explicit(api):
    client, _ = api
    import_csv(client, "2026-09-01 12:00:00,100.00,expense,payment,商店,购物,pay-1")
    original = transactions(client)["transactions"][0]
    operation_id = str(uuid.uuid4())
    changed = edit(client, original, {"category": "日用品", "tags": ["家庭"]}, operation_id=operation_id)
    assert changed.status_code == 200, changed.text
    assert changed.json()["transaction"]["version"] == 2
    assert changed.json()["transaction"]["category"] == "日用品"
    assert changed.json()["revision"] == 2
    replay = edit(client, original, {"category": "日用品", "tags": ["家庭"]}, operation_id=operation_id)
    assert replay.json() == changed.json()
    assert transactions(client)["revision"] == 2
    assert len(transactions(client, since=1)["transactions"]) == 1

    stale = edit(client, original, {"category": "其他"})
    assert stale.status_code == 409
    assert stale.json()["detail"] == "conflict"
    assert stale.json()["current"]["category"] == "日用品"
    assert transactions(client)["revision"] == 2
    reused = edit(client, original, {"note": "different"}, operation_id=operation_id)
    assert reused.status_code == 409


def test_cross_month_refund_and_red_packet_setting(api):
    client, _ = api
    import_csv(
        client,
        "2026-09-01 12:00:00,100.00,expense,payment,商店,购物,pay-1",
        "2026-10-01 12:00:00,40.00,income,refund,商店,部分退款,refund-1",
        "2026-09-02 12:00:00,20.00,expense,red_packet,朋友,红包,red-1",
        "2026-09-03 12:00:00,5.00,income,red_packet,朋友,红包,red-2",
    )
    by_external = {row["external_id"]: row for row in transactions(client)["transactions"]}
    assert by_external["red-1"]["excluded"] is True
    initial_october = client.get("/api/v1/reports/month?year=2026&month=10", headers=HEADER).json()
    assert initial_october["unlinked_refunds_cents"] == 4000
    assert initial_october["total_income_cents"] == 0

    linked = edit(client, by_external["refund-1"], {"refund_of_id": by_external["pay-1"]["id"]})
    assert linked.status_code == 200, linked.text
    september = client.get("/api/v1/reports/month?year=2026&month=9", headers=HEADER).json()
    october = client.get("/api/v1/reports/month?year=2026&month=10", headers=HEADER).json()
    assert september["gross_consumption_cents"] == 10000
    assert september["applied_refunds_cents"] == 4000
    assert september["total_actual_consumption_cents"] == 6000
    assert october["unlinked_refunds_cents"] == 0

    old_revision = transactions(client)["revision"]
    setting = client.patch("/api/v1/settings", headers=HEADER, json={"exclude_red_packets": False})
    assert setting.status_code == 200, setting.text
    assert setting.json()["settings"] == {"exclude_red_packets": False}
    changed = transactions(client, since=old_revision)
    assert changed["settings"] == {"exclude_red_packets": False}
    assert {row["external_id"] for row in changed["transactions"]} == {"red-1", "red-2"}
    assert all(row["excluded"] is False for row in changed["transactions"])
    september = client.get("/api/v1/reports/month?year=2026&month=9", headers=HEADER).json()
    assert september["total_actual_consumption_cents"] == 8000
    assert september["total_income_cents"] == 500

    # A manual choice has precedence when the default rule is changed again.
    red = next(row for row in changed["transactions"] if row["external_id"] == "red-1")
    assert edit(client, red, {"excluded": False}).status_code == 200
    assert client.patch("/api/v1/settings", headers=HEADER, json={"exclude_red_packets": True}).status_code == 200
    after = {row["external_id"]: row for row in transactions(client)["transactions"]}
    assert after["red-1"]["excluded"] is False
    assert after["red-2"]["excluded"] is True


def test_csv_export_escapes_formula_text(api):
    client, _ = api
    import_csv(client, "2026-09-01 12:00:00,1.00,expense,payment,商店,=1+1,pay-1")
    response = client.get("/api/v1/export.csv?year=2026&month=9", headers=HEADER)
    assert response.status_code == 200
    exported = list(csv.DictReader(io.StringIO(response.text.lstrip("\ufeff"))))
    assert len(exported) == 1
    assert exported[0]["description"] == "'=1+1"
    redacted = client.get("/api/v1/export.csv?year=2026&month=9&redact=true", headers=HEADER)
    redacted_row = list(csv.DictReader(io.StringIO(redacted.text.lstrip("\ufeff"))))[0]
    assert redacted_row["description"] == ""
    assert redacted_row["external_id"] == ""


def test_preview_can_use_explicit_column_mapping(api):
    client, _ = api
    content = "when,cost,flow\n2026-09-01 12:00:00,12.34,expense\n".encode()
    preview = client.post(
        "/api/v1/imports/preview",
        headers=HEADER,
        data={
            "source": "generic",
            "column_mapping": json.dumps({"occurred_at": "when", "amount": "cost", "direction": "flow"}),
        },
        files={"file": ("bill.csv", content, "text/csv")},
    )
    assert preview.status_code == 200, preview.text
    assert preview.json()["rows"][0]["amount_cents"] == 1234


def test_rules_apply_to_future_imports_and_manual_edit_stays_in_place(api):
    client, _ = api
    invalid = client.post(
        "/api/v1/rules", headers=HEADER,
        json={"conditions": {}, "actions": {"category": "餐饮"}},
    )
    assert invalid.status_code == 422
    created = client.post(
        "/api/v1/rules", headers=HEADER,
        json={
            "priority": 10,
            "conditions": {"merchant_contains": "咖啡店", "direction": "expense"},
            "actions": {"category": "餐饮", "tags": ["咖啡"]},
        },
    )
    assert created.status_code == 200, created.text
    rule_id = created.json()["rule"]["id"]
    assert client.get("/api/v1/rules", headers=HEADER).json()["rules"][0]["id"] == rule_id
    assert transactions(client)["rules"][0]["id"] == rule_id

    imported = import_csv(client, "2026-09-01 12:00:00,25.00,expense,payment,咖啡店,拿铁,pay-1")
    assert imported["preview"]["rows"][0]["category"] == "餐饮"
    original = transactions(client)["transactions"][0]
    assert original["category"] == "餐饮"
    assert original["tags"] == ["咖啡"]
    assert edit(client, original, {"category": "社交"}).status_code == 200
    assert client.delete(f"/api/v1/rules/{rule_id}", headers=HEADER).json()["deleted"] is True
    after = transactions(client)["transactions"][0]
    assert after["category"] == "社交"

    import_csv(client, "2026-09-02 12:00:00,30.00,expense,payment,咖啡店,拿铁,pay-2")
    later = {row["external_id"]: row for row in transactions(client)["transactions"]}
    assert later["pay-2"]["category"] is None


def test_transfer_default_can_be_manually_included_and_refund_is_capped(api):
    client, _ = api
    import_csv(
        client,
        "2026-09-01 12:00:00,100.00,expense,payment,商店,购物,pay-1",
        "2026-10-01 12:00:00,120.00,income,refund,商店,退款,refund-1",
        "2026-09-02 12:00:00,20.00,expense,transfer,朋友,转账,transfer-1",
    )
    by_external = {row["external_id"]: row for row in transactions(client)["transactions"]}
    assert by_external["transfer-1"]["excluded"] is True
    assert edit(client, by_external["refund-1"], {"refund_of_id": by_external["pay-1"]["id"]}).status_code == 200
    first = client.get("/api/v1/reports/month?year=2026&month=9", headers=HEADER).json()
    assert first["total_actual_consumption_cents"] == 0
    assert first["over_refund_cents"] == 2000

    assert edit(client, by_external["transfer-1"], {"excluded": False, "category": "赠与"}).status_code == 200
    second = client.get("/api/v1/reports/month?year=2026&month=9", headers=HEADER).json()
    assert second["total_actual_consumption_cents"] == 2000
    assert {row["category"]: row["amount_cents"] for row in second["category_totals"]}["赠与"] == 2000


def test_exclusion_rule_can_include_specific_red_packet(api):
    client, _ = api
    created = client.post(
        "/api/v1/rules", headers=HEADER,
        json={
            "conditions": {"merchant_contains": "特例", "kind": "red_packet"},
            "actions": {"excluded": False, "category": "赠与"},
        },
    )
    assert created.status_code == 200, created.text
    imported = import_csv(client, "2026-09-01 12:00:00,10.00,expense,red_packet,特例朋友,红包,red-1")
    assert imported["preview"]["rows"][0]["excluded"] is False
    red = transactions(client)["transactions"][0]
    assert red["excluded"] is False
    assert client.patch("/api/v1/settings", headers=HEADER, json={"exclude_red_packets": False}).status_code == 200
    assert client.patch("/api/v1/settings", headers=HEADER, json={"exclude_red_packets": True}).status_code == 200
    assert transactions(client)["transactions"][0]["excluded"] is False

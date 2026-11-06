"""Privacy regressions with synthetic identifiers only."""

from __future__ import annotations

import csv
import io
import json
import uuid
from contextlib import closing
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from app.db import connect
from app.main import create_app
from test_api import HEADER, TOKEN, api, edit, import_csv, transactions


PRIVATE_VALUE = "synthetic-private-account-123456"


@pytest.mark.parametrize("configured_token", [
    "", "x" * 23, "x" * 1025, "x" * 24 + " ", "x" * 24 + "\n", "私" * 24,
])
def test_invalid_configured_token_fails_startup_without_echo_or_database_creation(tmp_path, configured_token):
    database_path = tmp_path / "ledger.sqlite3"
    with pytest.raises(RuntimeError, match="24 to 1024 printable ASCII") as failure:
        with TestClient(create_app(database_path=database_path, api_token=configured_token)):
            pass
    assert not database_path.exists()
    if configured_token:
        assert configured_token not in str(failure.value)


@pytest.mark.parametrize("credential", [
    b"synthetic-private-token-\xff", b"x" * 1025, b"x" * 24 + b" ",
])
def test_malformed_incoming_tokens_return_private_401_instead_of_server_error(api, credential):
    client, _ = api
    response = client.get("/api/v1/sync", headers={b"Authorization": b"Bearer " + credential})
    assert response.status_code == 401
    assert response.json() == {"detail": "Invalid token"}
    assert response.headers["Cache-Control"] == "no-store"


def preview_payload(client, payload: str, *, source="generic", mapping=None):
    data = {"source": source}
    if mapping is not None:
        data["column_mapping"] = json.dumps(mapping)
    return client.post(
        "/api/v1/imports/preview", headers=HEADER, data=data,
        files={"file": ("synthetic.csv", payload.encode("utf-8"), "text/csv")},
    )


@pytest.mark.parametrize("source", ["alipay", "wechat"])
def test_unused_source_columns_are_neither_saved_nor_synced(api, source):
    client, db_path = api
    payload = (
        f"交易时间,金额(元),收/支,交易对方,商品,交易单号,对方账号,{PRIVATE_VALUE}\n"
        f"2026-10-01,1.00,支出,Synthetic shop,Item,synthetic-id,{PRIVATE_VALUE},{PRIVATE_VALUE}\n"
    )
    response = preview_payload(client, payload, source=source)
    assert response.status_code == 200, response.text
    assert PRIVATE_VALUE not in response.text
    draft = response.json()
    assert datetime.fromisoformat(draft["expires_at"]) > datetime.now(timezone.utc)
    with closing(connect(db_path)) as connection:
        stored = connection.execute("SELECT rows_json FROM import_previews").fetchone()[0]
        assert PRIVATE_VALUE not in stored
        assert json.loads(stored)[0]["raw_data"]["merchant"] == "Synthetic shop"
    committed = client.post(f"/api/v1/imports/{draft['preview_id']}/commit", headers=HEADER)
    assert committed.status_code == 200, committed.text
    with closing(connect(db_path)) as connection:
        raw = connection.execute("SELECT raw_json FROM transactions").fetchone()[0]
        assert PRIVATE_VALUE not in raw
        assert json.loads(raw)["external_id"] == "synthetic-id"
        preview = connection.execute("SELECT * FROM import_previews").fetchone()
        assert preview["rows_json"] == "[]"
        assert json.loads(preview["commit_response_json"]) == committed.json()
    synced = client.get("/api/v1/sync", headers=HEADER)
    assert PRIVATE_VALUE not in synced.text
    assert all("raw_data" not in row and "raw_json" not in row for row in synced.json()["transactions"])
    assert client.post(f"/api/v1/imports/{draft['preview_id']}/commit", headers=HEADER).json() == committed.json()


def test_custom_private_header_names_are_not_retained(api):
    client, db_path = api
    response = preview_payload(
        client,
        f"occurred_at,amount,direction,{PRIVATE_VALUE}\n2026-10-01,1.00,expense,Useful description\n",
        mapping={"description": PRIVATE_VALUE},
    )
    assert response.status_code == 200, response.text
    with closing(connect(db_path)) as connection:
        stored = connection.execute("SELECT rows_json FROM import_previews").fetchone()[0]
    assert PRIVATE_VALUE not in stored
    assert json.loads(stored)[0]["raw_data"]["description"] == "Useful description"


@pytest.mark.parametrize("field", ["occurred_at", "amount", "direction"])
def test_import_errors_show_field_and_row_without_repeating_private_cells(api, field):
    client, _ = api
    row = {"occurred_at": "2026-10-01", "amount": "1.00", "direction": "expense"}
    row[field] = PRIVATE_VALUE
    response = preview_payload(client, ",".join(row) + "\n" + ",".join(row.values()) + "\n")
    assert response.status_code == 422
    assert PRIVATE_VALUE not in response.text
    assert "第 2 行" in response.json()["detail"]


@pytest.mark.parametrize("mapping", [
    {"note": PRIVATE_VALUE},
    {PRIVATE_VALUE: "description"},
])
def test_mapping_errors_do_not_repeat_custom_headers_or_keys(api, mapping):
    client, _ = api
    response = preview_payload(
        client, "occurred_at,amount,direction\n2026-10-01,1.00,expense\n", mapping=mapping,
    )
    assert response.status_code == 422
    assert PRIVATE_VALUE not in response.text


@pytest.mark.parametrize("payload", [
    {"exclude_red_packets": PRIVATE_VALUE},
    {"exclude_red_packets": True, PRIVATE_VALUE: {"note": PRIVATE_VALUE}},
])
def test_request_validation_omits_invalid_values_and_unknown_property_names(api, payload):
    client, _ = api
    response = client.patch("/api/v1/settings", headers=HEADER, json=payload)
    assert response.status_code == 422
    assert PRIVATE_VALUE not in response.text
    assert all("input" not in item and "ctx" not in item for item in response.json()["detail"])


def test_nested_model_validation_does_not_echo_private_rule(api):
    client, _ = api
    response = client.post("/api/v1/rules", headers=HEADER, json={
        "conditions": {"merchant_contains": PRIVATE_VALUE},
        "actions": {"category": "", "tags": [PRIVATE_VALUE]},
    })
    assert response.status_code == 422
    assert PRIVATE_VALUE not in response.text
    malformed = client.patch(
        "/api/v1/settings", headers={**HEADER, "Content-Type": "application/json"},
        content='{"' + PRIVATE_VALUE + '":',
    )
    assert malformed.status_code == 422
    assert PRIVATE_VALUE not in malformed.text


def test_expired_previews_are_removed_without_losing_committed_import_receipts(api):
    client, db_path = api
    imported = import_csv(client, "2026-10-01,1.00,expense,payment,Shop,Item,first")
    pending = preview_payload(
        client, "occurred_at,amount,direction\n2026-10-02,2.00,expense\n",
    ).json()
    stale_at = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()
    with closing(connect(db_path)) as connection:
        connection.execute("UPDATE import_previews SET created_at = ?", (stale_at,))
    expired = client.post(f"/api/v1/imports/{pending['preview_id']}/commit", headers=HEADER)
    assert expired.status_code == 404
    assert "expired" in expired.json()["detail"]
    replay = client.post(f"/api/v1/imports/{imported['preview']['preview_id']}/commit", headers=HEADER)
    assert replay.json() == imported["commit"]
    with closing(connect(db_path)) as connection:
        assert connection.execute("SELECT COUNT(*) FROM import_previews").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM transactions").fetchone()[0] == 1


def test_startup_removes_legacy_preview_copies_but_preserves_existing_ledger_raw_data(api):
    client, db_path = api
    imported = import_csv(client, "2026-10-01,1.00,expense,payment,Shop,Item,first")
    preview_id = imported["preview"]["preview_id"]
    with closing(connect(db_path)) as connection:
        connection.execute("UPDATE transactions SET raw_json = ?", (json.dumps({"legacy": PRIVATE_VALUE}),))
        connection.execute("UPDATE import_previews SET rows_json = ? WHERE id = ?", (json.dumps([PRIVATE_VALUE]), preview_id))
        connection.execute(
            "INSERT INTO import_previews (id, source, created_at, rows_json) VALUES (?, ?, ?, ?)",
            (str(uuid.uuid4()), "generic", "2020-01-01T00:00:00+00:00", json.dumps([PRIVATE_VALUE])),
        )
    with TestClient(create_app(database_path=db_path, api_token=TOKEN)) as restarted:
        assert restarted.post(f"/api/v1/imports/{preview_id}/commit", headers=HEADER).json() == imported["commit"]
        assert PRIVATE_VALUE not in restarted.get("/api/v1/sync", headers=HEADER).text
    with closing(connect(db_path)) as connection:
        assert connection.execute("SELECT rows_json FROM import_previews").fetchall()[0][0] == "[]"
        assert connection.execute("SELECT COUNT(*) FROM import_previews").fetchone()[0] == 1
        assert json.loads(connection.execute("SELECT raw_json FROM transactions").fetchone()[0])["legacy"] == PRIVATE_VALUE


def test_redacted_csv_preserves_groups_and_refund_joins_with_ephemeral_ids(api):
    client, _ = api
    import_csv(
        client,
        "2026-10-01,10.00,expense,payment,Shop,Item,purchase",
        "2026-10-02,2.00,income,refund,Shop,Refund,refund",
        "2026-10-03,3.00,expense,payment,Shop,Other,other",
    )
    rows = {row["external_id"]: row for row in transactions(client)["transactions"]}
    assert edit(client, rows["purchase"], {"category": PRIVATE_VALUE}).status_code == 200
    assert edit(client, rows["refund"], {"category": PRIVATE_VALUE, "refund_of_id": rows["purchase"]["id"]}).status_code == 200
    assert edit(client, rows["other"], {"category": "Another private category"}).status_code == 200
    response = client.get("/api/v1/export.csv?redact=true", headers=HEADER)
    assert response.status_code == 200
    assert PRIVATE_VALUE not in response.text
    assert "Another private category" not in response.text
    for row in rows.values():
        assert row["id"] not in response.text
    exported = list(csv.DictReader(io.StringIO(response.text.lstrip("\ufeff"))))
    assert exported[0]["category"] == exported[1]["category"] == "分类1"
    assert exported[2]["category"] == "分类2"
    assert exported[1]["refund_of_id"] == exported[0]["id"]
    second = client.get("/api/v1/export.csv?redact=true", headers=HEADER)
    assert exported[0]["id"] not in second.text
    full = client.get("/api/v1/export.csv", headers=HEADER)
    assert PRIVATE_VALUE in full.text
    assert rows["purchase"]["id"] in full.text


@pytest.mark.parametrize("endpoint,headers", [
    ("/api/v1/sync", HEADER),
    ("/api/v1/export.csv", HEADER),
    ("/api/v1/export.csv?year=invalid", HEADER),
    ("/api/v1/sync", {}),
])
def test_private_api_success_and_error_responses_are_not_cacheable(api, endpoint, headers):
    client, _ = api
    response = client.get(endpoint, headers=headers)
    assert response.headers["Cache-Control"] == "no-store"
    assert response.headers["Pragma"] == "no-cache"

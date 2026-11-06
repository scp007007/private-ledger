"""SQLite storage and transaction serialization for the ledger API."""

from __future__ import annotations

import json
import sqlite3
import uuid
from contextlib import closing
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


IMPORT_PREVIEW_TTL = timedelta(hours=24)


SCHEMA = """
CREATE TABLE IF NOT EXISTS ledger_meta (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    revision INTEGER NOT NULL DEFAULT 0,
    exclude_red_packets INTEGER NOT NULL DEFAULT 1 CHECK (exclude_red_packets IN (0, 1)),
    ledger_id TEXT
);
INSERT OR IGNORE INTO ledger_meta (id, revision, exclude_red_packets) VALUES (1, 0, 1);

CREATE TABLE IF NOT EXISTS transactions (
    id TEXT PRIMARY KEY,
    source TEXT NOT NULL CHECK (source IN ('alipay', 'wechat', 'manual', 'generic')),
    external_id TEXT,
    dedupe_key TEXT NOT NULL UNIQUE,
    occurred_at TEXT NOT NULL,
    amount_cents INTEGER NOT NULL CHECK (amount_cents > 0),
    direction TEXT NOT NULL CHECK (direction IN ('expense', 'income')),
    kind TEXT NOT NULL CHECK (kind IN ('payment', 'refund', 'transfer', 'red_packet', 'other')),
    merchant TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    category TEXT,
    tags_json TEXT NOT NULL DEFAULT '[]',
    note TEXT NOT NULL DEFAULT '',
    excluded INTEGER NOT NULL DEFAULT 0 CHECK (excluded IN (0, 1)),
    exclusion_reason TEXT,
    excluded_override INTEGER CHECK (excluded_override IN (0, 1)),
    refund_of_id TEXT REFERENCES transactions(id),
    raw_json TEXT NOT NULL,
    version INTEGER NOT NULL DEFAULT 1,
    revision INTEGER NOT NULL,
    CHECK (refund_of_id IS NULL OR refund_of_id <> id)
);
CREATE INDEX IF NOT EXISTS transactions_revision_idx ON transactions(revision);
CREATE INDEX IF NOT EXISTS transactions_occurred_idx ON transactions(occurred_at);
CREATE INDEX IF NOT EXISTS transactions_refund_idx ON transactions(refund_of_id);

CREATE TABLE IF NOT EXISTS edit_operations (
    operation_id TEXT PRIMARY KEY,
    request_hash TEXT NOT NULL,
    response_json TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS import_previews (
    id TEXT PRIMARY KEY,
    source TEXT NOT NULL,
    created_at TEXT NOT NULL,
    rows_json TEXT NOT NULL,
    committed_at TEXT,
    commit_response_json TEXT
);

CREATE TABLE IF NOT EXISTS rules (
    id TEXT PRIMARY KEY,
    enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
    priority INTEGER NOT NULL,
    conditions_json TEXT NOT NULL,
    actions_json TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS rules_order_idx ON rules(priority, id);
"""


def connect(db_path: str | Path) -> sqlite3.Connection:
    connection = sqlite3.connect(str(db_path), timeout=30, isolation_level=None)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys = ON")
    connection.execute("PRAGMA busy_timeout = 30000")
    return connection


def initialize(db_path: str | Path) -> None:
    path = Path(db_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with closing(connect(path)) as connection:
        connection.execute("PRAGMA journal_mode = WAL")
        connection.executescript(SCHEMA)
        connection.execute("BEGIN IMMEDIATE")
        columns = {
            row["name"] for row in connection.execute("PRAGMA table_info(ledger_meta)").fetchall()
        }
        if "ledger_id" not in columns:
            connection.execute("ALTER TABLE ledger_meta ADD COLUMN ledger_id TEXT")
        connection.execute(
            "UPDATE ledger_meta SET ledger_id = ? WHERE id = 1 AND (ledger_id IS NULL OR ledger_id = '')",
            (str(uuid.uuid4()),),
        )
        prune_import_previews(connection)
        connection.commit()


def prune_import_previews(connection: sqlite3.Connection) -> None:
    """Discard temporary bill copies while keeping committed import receipts."""
    cutoff = (datetime.now(timezone.utc) - IMPORT_PREVIEW_TTL).isoformat()
    connection.execute(
        "DELETE FROM import_previews WHERE committed_at IS NULL "
        "AND commit_response_json IS NULL AND created_at < ?",
        (cutoff,),
    )
    connection.execute(
        "UPDATE import_previews SET rows_json = '[]' "
        "WHERE commit_response_json IS NOT NULL AND rows_json <> '[]'"
    )


def current_revision(connection: sqlite3.Connection) -> int:
    return int(connection.execute("SELECT revision FROM ledger_meta WHERE id = 1").fetchone()[0])


def ledger_id(connection: sqlite3.Connection) -> str:
    return str(connection.execute("SELECT ledger_id FROM ledger_meta WHERE id = 1").fetchone()[0])


def next_revision(connection: sqlite3.Connection) -> int:
    connection.execute("UPDATE ledger_meta SET revision = revision + 1 WHERE id = 1")
    return current_revision(connection)


def settings(connection: sqlite3.Connection) -> dict[str, bool]:
    value = connection.execute("SELECT exclude_red_packets FROM ledger_meta WHERE id = 1").fetchone()[0]
    return {"exclude_red_packets": bool(value)}


def transaction_dict(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "source": row["source"],
        "external_id": row["external_id"],
        "occurred_at": row["occurred_at"],
        "amount_cents": row["amount_cents"],
        "direction": row["direction"],
        "kind": row["kind"],
        "merchant": row["merchant"],
        "description": row["description"],
        "category": row["category"],
        "tags": json.loads(row["tags_json"]),
        "note": row["note"],
        "excluded": bool(row["excluded"]),
        "exclusion_reason": row["exclusion_reason"],
        "refund_of_id": row["refund_of_id"],
        "version": row["version"],
        "revision": row["revision"],
    }

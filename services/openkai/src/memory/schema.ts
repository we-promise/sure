import Database from 'better-sqlite3';
import { randomUUID } from 'node:crypto';

// --- Entity types: OpenKai originals + financial extensions ---

export const ENTITY_TYPES = [
  // Core knowledge types (from OpenKai)
  'concept',
  'fact',
  'person',
  'preference',
  'pattern',
  'reflection',
  'self_model',
  // Financial domain types
  'financial_goal',
  'spending_pattern',
  'income_source',
  'budget_rule',
  'financial_milestone',
  'risk_preference',
  'life_event',
  'account_context',
] as const;

export const RELATION_TYPES = [
  'relates_to',
  'part_of',
  'learned_from',
  'depends_on',
  'contradicts',
  'supersedes',
  'caused_by',
  'evolved_from',
  'reinforced_by',
] as const;

export const AUDIT_ACTIONS = [
  'create',
  'update',
  'delete',
  'search',
  'access',
] as const;

// --- Type Definitions ---

export type EntityType = (typeof ENTITY_TYPES)[number];
export type RelationType = (typeof RELATION_TYPES)[number];
export type AuditAction = (typeof AUDIT_ACTIONS)[number];

export interface Entity {
  id: string;
  name: string;
  type: EntityType;
  content: string;
  source: string | null;
  confidence: number;
  weight: number;
  created_at: string;
  updated_at: string;
  accessed_at: string;
  valid_from: string | null;
  valid_until: string | null;
}

export interface Relation {
  id: string;
  from_entity: string;
  to_entity: string;
  type: RelationType;
  weight: number;
  created_at: string;
}

export interface AuditEntry {
  id: number;
  action: AuditAction;
  entity_id: string | null;
  details: string | null;
  actor: string;
  created_at: string;
}

// --- Schema SQL ---

const ENTITY_TYPE_CHECK = ENTITY_TYPES.map((t) => `'${t}'`).join(', ');
const RELATION_TYPE_CHECK = RELATION_TYPES.map((t) => `'${t}'`).join(', ');
const AUDIT_ACTION_CHECK = AUDIT_ACTIONS.map((a) => `'${a}'`).join(', ');

const SCHEMA_SQL = `
  -- Knowledge graph nodes
  CREATE TABLE IF NOT EXISTS entities (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    type        TEXT NOT NULL CHECK(type IN (${ENTITY_TYPE_CHECK})),
    content     TEXT NOT NULL,
    source      TEXT,
    confidence  REAL NOT NULL DEFAULT 1.0 CHECK(confidence >= 0.0 AND confidence <= 1.0),
    weight      REAL NOT NULL DEFAULT 3.0 CHECK(weight >= 1.0 AND weight <= 5.0),
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL,
    accessed_at TEXT NOT NULL,
    valid_from  TEXT,
    valid_until TEXT
  );

  -- Edges between entities
  CREATE TABLE IF NOT EXISTS relations (
    id          TEXT PRIMARY KEY,
    from_entity TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    to_entity   TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    type        TEXT NOT NULL CHECK(type IN (${RELATION_TYPE_CHECK})),
    weight      REAL NOT NULL DEFAULT 1.0,
    created_at  TEXT NOT NULL
  );

  -- Append-only audit trail
  CREATE TABLE IF NOT EXISTS audit_log (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    action     TEXT NOT NULL CHECK(action IN (${AUDIT_ACTION_CHECK})),
    entity_id  TEXT,
    details    TEXT,
    actor      TEXT NOT NULL DEFAULT 'system',
    created_at TEXT NOT NULL
  );

  -- Chat session history for this tenant
  CREATE TABLE IF NOT EXISTS sessions (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    role      TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
    content   TEXT NOT NULL,
    timestamp TEXT NOT NULL
  );

  -- Budget tracking per day
  CREATE TABLE IF NOT EXISTS budget_log (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    date       TEXT NOT NULL,
    model      TEXT NOT NULL,
    input_tokens  INTEGER NOT NULL,
    output_tokens INTEGER NOT NULL,
    cost_usd   REAL NOT NULL,
    created_at TEXT NOT NULL
  );

  -- Indexes
  CREATE INDEX IF NOT EXISTS idx_entities_type       ON entities(type);
  CREATE INDEX IF NOT EXISTS idx_entities_weight     ON entities(weight);
  CREATE INDEX IF NOT EXISTS idx_relations_from      ON relations(from_entity);
  CREATE INDEX IF NOT EXISTS idx_relations_to        ON relations(to_entity);
  CREATE INDEX IF NOT EXISTS idx_audit_entity_id     ON audit_log(entity_id);
  CREATE INDEX IF NOT EXISTS idx_audit_created_at    ON audit_log(created_at);
  CREATE INDEX IF NOT EXISTS idx_sessions_timestamp  ON sessions(timestamp);
  CREATE INDEX IF NOT EXISTS idx_budget_date         ON budget_log(date);
`;

// FTS5 for BM25 search
const FTS_SQL = `
  CREATE VIRTUAL TABLE IF NOT EXISTS entities_fts
  USING fts5(name, content, content=entities, content_rowid=rowid);
`;

// Triggers to keep FTS in sync
const FTS_TRIGGERS_SQL = `
  CREATE TRIGGER IF NOT EXISTS entities_fts_insert AFTER INSERT ON entities BEGIN
    INSERT INTO entities_fts(rowid, name, content) VALUES (NEW.rowid, NEW.name, NEW.content);
  END;

  CREATE TRIGGER IF NOT EXISTS entities_fts_delete AFTER DELETE ON entities BEGIN
    INSERT INTO entities_fts(entities_fts, rowid, name, content) VALUES ('delete', OLD.rowid, OLD.name, OLD.content);
  END;

  CREATE TRIGGER IF NOT EXISTS entities_fts_update AFTER UPDATE ON entities BEGIN
    INSERT INTO entities_fts(entities_fts, rowid, name, content) VALUES ('delete', OLD.rowid, OLD.name, OLD.content);
    INSERT INTO entities_fts(rowid, name, content) VALUES (NEW.rowid, NEW.name, NEW.content);
  END;
`;

// --- Database Initialization ---

/**
 * Creates or opens the SQLite database at `dbPath`, runs schema + migrations.
 * Idempotent — safe to call on every startup / tenant access.
 */
export function initDatabase(dbPath: string): Database.Database {
  const db = new Database(dbPath);

  // Performance & reliability pragmas
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  db.pragma('busy_timeout = 5000');

  // Core schema
  db.exec(SCHEMA_SQL);

  // FTS5 + sync triggers
  db.exec(FTS_SQL);
  db.exec(FTS_TRIGGERS_SQL);

  return db;
}

// --- Helpers ---

export function generateId(): string {
  return randomUUID();
}

export function now(): string {
  return new Date().toISOString();
}

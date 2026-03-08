import Database from 'better-sqlite3';
import type { Entity } from './schema.js';

// --- Interfaces ---

export interface SearchResult {
  entity: Entity;
  score: number;
  bm25_score: number;
}

export interface SearchOptions {
  query: string;
  limit?: number;
  type?: string;
  minWeight?: number;
}

interface ScoredResult {
  entity_id: string;
  score: number;
}

// --- BM25-only search for v1 (no vector embeddings, no Ollama) ---

export class MemorySearch {
  private db: Database.Database;
  private reinforceStmt!: ReturnType<Database.Database['prepare']>;
  private stmtsPrepared = false;

  constructor(db: Database.Database) {
    this.db = db;
  }

  private ensureStmts(): void {
    if (!this.stmtsPrepared) {
      this.reinforceStmt = this.db.prepare(`
        UPDATE entities
        SET weight = MIN(5.0, weight + 0.05), accessed_at = @now
        WHERE id = @id AND weight < 5.0
      `);
      this.stmtsPrepared = true;
    }
  }

  /**
   * Search the knowledge graph using BM25 keyword matching via FTS5.
   */
  search(options: SearchOptions): SearchResult[] {
    const limit = options.limit ?? 10;
    const bm25Results = this.bm25Search(
      options.query,
      limit,
      options.type,
      options.minWeight,
    );

    if (bm25Results.length === 0) return [];

    // Fetch full entities
    const entityIds = bm25Results.map((r) => r.entity_id);
    const placeholders = entityIds.map(() => '?').join(', ');
    const entities: Entity[] = this.db
      .prepare(`SELECT * FROM entities WHERE id IN (${placeholders})`)
      .all(...entityIds) as Entity[];

    const entityMap = new Map<string, Entity>();
    for (const entity of entities) {
      entityMap.set(entity.id, entity);
    }

    const results: SearchResult[] = [];
    for (const r of bm25Results) {
      const entity = entityMap.get(r.entity_id);
      if (!entity) continue;

      results.push({
        entity,
        score: r.score,
        bm25_score: r.score,
      });
    }

    // Retrieval reinforcement
    this.reinforceResults(results);

    return results;
  }

  /**
   * BM25 keyword search using SQLite FTS5.
   */
  bm25Search(
    query: string,
    limit: number,
    type?: string,
    minWeight?: number,
  ): ScoredResult[] {
    // Escape FTS5 special characters, wrap tokens in quotes, OR them
    const sanitized = query
      .split(/\s+/)
      .filter((token) => token.length > 0)
      .map((token) => `"${token.replace(/"/g, '""')}"`)
      .join(' OR ');

    if (sanitized.length === 0) return [];

    let sql = `
      SELECT ent.id AS entity_id, fts.rank AS rank
      FROM entities_fts fts
      JOIN entities ent ON ent.rowid = fts.rowid
      WHERE entities_fts MATCH ?
    `;
    const params: unknown[] = [sanitized];

    if (type) {
      sql += ' AND ent.type = ?';
      params.push(type);
    }
    if (minWeight !== undefined) {
      sql += ' AND ent.weight >= ?';
      params.push(minWeight);
    }

    sql += ' ORDER BY fts.rank LIMIT ?';
    params.push(limit);

    const rows = this.db.prepare(sql).all(...params) as Array<{
      entity_id: string;
      rank: number;
    }>;

    if (rows.length === 0) return [];

    // Normalize: FTS5 rank is negative. Most negative = best.
    const bestRank = rows[0].rank;
    const worstRank = rows[rows.length - 1].rank;
    const range = bestRank - worstRank;

    return rows.map((row) => ({
      entity_id: row.entity_id,
      score: range === 0 ? 1.0 : (row.rank - worstRank) / range,
    }));
  }

  /**
   * Bump weight (+0.05, capped at 5.0) for retrieved entities.
   * Frequently retrieved memories naturally rise in weight.
   */
  private reinforceResults(results: SearchResult[]): void {
    if (results.length === 0) return;

    this.ensureStmts();
    const now = new Date().toISOString();

    const reinforce = this.db.transaction(() => {
      for (const r of results) {
        this.reinforceStmt.run({ id: r.entity.id, now });
      }
    });

    reinforce();
  }
}

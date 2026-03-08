import Database from 'better-sqlite3';
import crypto from 'node:crypto';
import type { Entity, Relation } from './schema.js';
import { ENTITY_TYPES, RELATION_TYPES } from './schema.js';

export class KnowledgeGraph {
  private db: Database.Database;
  private stmts!: ReturnType<KnowledgeGraph['prepareStatements']>;
  private prepared = false;

  constructor(db: Database.Database) {
    this.db = db;
  }

  private ensurePrepared(): void {
    if (!this.prepared) {
      this.stmts = this.prepareStatements();
      this.prepared = true;
    }
  }

  private prepareStatements() {
    return {
      insertEntity: this.db.prepare<{
        id: string;
        name: string;
        type: string;
        content: string;
        source: string | null;
        confidence: number;
        weight: number;
        created_at: string;
        updated_at: string;
        accessed_at: string;
        valid_from: string | null;
        valid_until: string | null;
      }>(`
        INSERT INTO entities (id, name, type, content, source, confidence, weight, created_at, updated_at, accessed_at, valid_from, valid_until)
        VALUES (@id, @name, @type, @content, @source, @confidence, @weight, @created_at, @updated_at, @accessed_at, @valid_from, @valid_until)
      `),

      getEntity: this.db.prepare<{ id: string }>(`
        SELECT * FROM entities WHERE id = @id
      `),

      updateAccessedAt: this.db.prepare<{ id: string; accessed_at: string }>(`
        UPDATE entities SET accessed_at = @accessed_at WHERE id = @id
      `),

      deleteEntity: this.db.prepare<{ id: string }>(`
        DELETE FROM entities WHERE id = @id
      `),

      deleteEntityRelations: this.db.prepare<{ id: string }>(`
        DELETE FROM relations WHERE from_entity = @id OR to_entity = @id
      `),

      insertRelation: this.db.prepare<{
        id: string;
        from_entity: string;
        to_entity: string;
        type: string;
        weight: number;
        created_at: string;
      }>(`
        INSERT INTO relations (id, from_entity, to_entity, type, weight, created_at)
        VALUES (@id, @from_entity, @to_entity, @type, @weight, @created_at)
      `),

      getRelationsFrom: this.db.prepare<{ id: string }>(`
        SELECT * FROM relations WHERE from_entity = @id
      `),

      getRelationsTo: this.db.prepare<{ id: string }>(`
        SELECT * FROM relations WHERE to_entity = @id
      `),

      getRelationsBoth: this.db.prepare<{ id: string }>(`
        SELECT * FROM relations WHERE from_entity = @id OR to_entity = @id
      `),

      deleteRelation: this.db.prepare<{ id: string }>(`
        DELETE FROM relations WHERE id = @id
      `),

      countEntities: this.db.prepare(`SELECT COUNT(*) as count FROM entities`),

      countRelations: this.db.prepare(`SELECT COUNT(*) as count FROM relations`),

      countEntitiesByType: this.db.prepare(`
        SELECT type, COUNT(*) as count FROM entities GROUP BY type
      `),

      findByName: this.db.prepare<{ name: string }>(`
        SELECT * FROM entities WHERE LOWER(name) = LOWER(@name) LIMIT 1
      `),
    };
  }

  // --- Entity CRUD ---

  createEntity(params: {
    name: string;
    type: (typeof ENTITY_TYPES)[number];
    content: string;
    source?: string;
    confidence?: number;
    weight?: number;
    valid_from?: string | null;
    valid_until?: string | null;
  }): Entity {
    this.ensurePrepared();

    const now = new Date().toISOString();
    const entity: Entity = {
      id: crypto.randomUUID(),
      name: params.name,
      type: params.type,
      content: params.content,
      source: params.source ?? null,
      confidence: params.confidence ?? 1.0,
      weight: params.weight ?? 3.0,
      created_at: now,
      updated_at: now,
      accessed_at: now,
      valid_from: params.valid_from ?? null,
      valid_until: params.valid_until ?? null,
    };

    this.stmts.insertEntity.run(entity);
    return entity;
  }

  getEntity(id: string): Entity | null {
    this.ensurePrepared();

    const row = this.stmts.getEntity.get({ id }) as Entity | undefined;
    if (!row) return null;

    const now = new Date().toISOString();
    this.stmts.updateAccessedAt.run({ id, accessed_at: now });
    row.accessed_at = now;

    return row;
  }

  updateEntity(
    id: string,
    updates: Partial<
      Pick<Entity, 'name' | 'content' | 'type' | 'confidence' | 'weight' | 'valid_from' | 'valid_until'>
    >,
  ): Entity | null {
    this.ensurePrepared();

    const existing = this.stmts.getEntity.get({ id }) as Entity | undefined;
    if (!existing) return null;

    const fields: string[] = [];
    const values: Record<string, unknown> = { id };

    if (updates.name !== undefined) {
      fields.push('name = @name');
      values.name = updates.name;
    }
    if (updates.content !== undefined) {
      fields.push('content = @content');
      values.content = updates.content;
    }
    if (updates.type !== undefined) {
      fields.push('type = @type');
      values.type = updates.type;
    }
    if (updates.confidence !== undefined) {
      fields.push('confidence = @confidence');
      values.confidence = updates.confidence;
    }
    if (updates.weight !== undefined) {
      fields.push('weight = @weight');
      values.weight = updates.weight;
    }
    if (updates.valid_from !== undefined) {
      fields.push('valid_from = @valid_from');
      values.valid_from = updates.valid_from;
    }
    if (updates.valid_until !== undefined) {
      fields.push('valid_until = @valid_until');
      values.valid_until = updates.valid_until;
    }

    if (fields.length === 0) return existing;

    const now = new Date().toISOString();
    fields.push('updated_at = @updated_at');
    values.updated_at = now;

    const sql = `UPDATE entities SET ${fields.join(', ')} WHERE id = @id`;
    this.db.prepare(sql).run(values);

    return this.stmts.getEntity.get({ id }) as Entity;
  }

  deleteEntity(id: string): boolean {
    this.ensurePrepared();

    const existing = this.stmts.getEntity.get({ id }) as Entity | undefined;
    if (!existing) return false;

    this.stmts.deleteEntityRelations.run({ id });
    this.stmts.deleteEntity.run({ id });

    return true;
  }

  listEntities(options?: {
    type?: (typeof ENTITY_TYPES)[number];
    limit?: number;
    offset?: number;
    minWeight?: number;
  }): Entity[] {
    this.ensurePrepared();

    const conditions: string[] = [];
    const values: Record<string, unknown> = {};

    if (options?.type) {
      conditions.push('type = @type');
      values.type = options.type;
    }
    if (options?.minWeight !== undefined) {
      conditions.push('weight >= @minWeight');
      values.minWeight = options.minWeight;
    }

    const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';
    const limit = options?.limit ?? 100;
    const offset = options?.offset ?? 0;

    const sql = `SELECT * FROM entities ${where} ORDER BY updated_at DESC LIMIT @limit OFFSET @offset`;
    values.limit = limit;
    values.offset = offset;

    return this.db.prepare(sql).all(values) as Entity[];
  }

  // --- Relation CRUD ---

  createRelation(params: {
    from_entity: string;
    to_entity: string;
    type: (typeof RELATION_TYPES)[number];
    weight?: number;
  }): Relation {
    this.ensurePrepared();

    const from = this.stmts.getEntity.get({ id: params.from_entity }) as Entity | undefined;
    if (!from) throw new Error(`Source entity not found: ${params.from_entity}`);
    const to = this.stmts.getEntity.get({ id: params.to_entity }) as Entity | undefined;
    if (!to) throw new Error(`Target entity not found: ${params.to_entity}`);

    const relation: Relation = {
      id: crypto.randomUUID(),
      from_entity: params.from_entity,
      to_entity: params.to_entity,
      type: params.type,
      weight: params.weight ?? 1.0,
      created_at: new Date().toISOString(),
    };

    this.stmts.insertRelation.run(relation);
    return relation;
  }

  getRelations(entityId: string, direction: 'from' | 'to' | 'both' = 'both'): Relation[] {
    this.ensurePrepared();

    switch (direction) {
      case 'from':
        return this.stmts.getRelationsFrom.all({ id: entityId }) as Relation[];
      case 'to':
        return this.stmts.getRelationsTo.all({ id: entityId }) as Relation[];
      case 'both':
        return this.stmts.getRelationsBoth.all({ id: entityId }) as Relation[];
    }
  }

  deleteRelation(id: string): boolean {
    this.ensurePrepared();
    const result = this.stmts.deleteRelation.run({ id });
    return result.changes > 0;
  }

  findEntityByName(name: string): Entity | null {
    this.ensurePrepared();
    return (this.stmts.findByName.get({ name }) as Entity | undefined) ?? null;
  }

  stats(): {
    total_entities: number;
    total_relations: number;
    entities_by_type: Record<string, number>;
  } {
    this.ensurePrepared();

    const totalEntities = (this.stmts.countEntities.get() as { count: number }).count;
    const totalRelations = (this.stmts.countRelations.get() as { count: number }).count;

    const typeCounts = this.stmts.countEntitiesByType.all() as { type: string; count: number }[];
    const entitiesByType: Record<string, number> = {};
    for (const row of typeCounts) {
      entitiesByType[row.type] = row.count;
    }

    return {
      total_entities: totalEntities,
      total_relations: totalRelations,
      entities_by_type: entitiesByType,
    };
  }
}

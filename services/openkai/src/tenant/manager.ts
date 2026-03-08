import { mkdirSync } from 'node:fs';
import { resolve } from 'node:path';
import Database from 'better-sqlite3';
import type { MemoryConfig } from '../config.js';
import { initDatabase } from '../memory/schema.js';
import { KnowledgeGraph } from '../memory/knowledge-graph.js';
import { MemorySearch } from '../memory/search.js';
import { MemoryFlush, type ExtractedFact, type DedupDecision } from '../memory/memory-flush.js';
import type { ClaudeClient } from '../intelligence/claude-client.js';

export interface TenantContext {
  familyId: string;
  db: Database.Database;
  kg: KnowledgeGraph;
  search: MemorySearch;
  flush: MemoryFlush;
}

interface CacheEntry {
  tenant: TenantContext;
  lastAccess: number;
}

export interface TenantManagerOptions {
  memoryConfig: MemoryConfig;
  claudeClient: ClaudeClient;
  extractionModel: string;
}

/**
 * Manages per-family SQLite databases with LRU eviction.
 * Each family gets an isolated KG, search index, and memory flush pipeline.
 *
 * IMPORTANT: Receives a shared ClaudeClient instance from the router.
 * This ensures all API calls (conversation + extraction + dedup) share
 * a single budget counter.
 */
export class TenantManager {
  private cache: Map<string, CacheEntry> = new Map();
  private maxCached: number;
  private dataDir: string;
  private claudeClient: ClaudeClient;
  private extractionModel: string;

  constructor(options: TenantManagerOptions) {
    this.maxCached = options.memoryConfig.max_cached_tenants;
    this.dataDir = options.memoryConfig.data_dir;
    this.claudeClient = options.claudeClient;
    this.extractionModel = options.extractionModel;
  }

  /**
   * Get or create a tenant context for a family.
   * Lazy-initializes SQLite DB, runs migrations, creates KG/search/flush.
   */
  async getTenant(familyId: string): Promise<TenantContext> {
    const existing = this.cache.get(familyId);
    if (existing) {
      existing.lastAccess = Date.now();
      return existing.tenant;
    }

    // Evict LRU if at capacity
    if (this.cache.size >= this.maxCached) {
      this.evictLRU();
    }

    const tenant = this.createTenant(familyId);
    this.cache.set(familyId, { tenant, lastAccess: Date.now() });
    return tenant;
  }

  /**
   * Close all open database connections.
   */
  closeAll(): void {
    for (const [, entry] of this.cache) {
      try {
        entry.tenant.db.close();
      } catch {
        // Ignore close errors during shutdown
      }
    }
    this.cache.clear();
  }

  get openTenants(): number {
    return this.cache.size;
  }

  private createTenant(familyId: string): TenantContext {
    const tenantDir = resolve(this.dataDir, 'tenants', familyId);
    const brainDir = resolve(tenantDir, 'brain');
    const dbPath = resolve(tenantDir, 'knowledge.db');

    // Ensure directories exist
    mkdirSync(brainDir, { recursive: true });

    // Initialize database
    const db = initDatabase(dbPath);
    const kg = new KnowledgeGraph(db);
    const search = new MemorySearch(db);

    // Build extraction function using Haiku (cheap — extraction is formatting, not reasoning)
    const extractFn = async (text: string): Promise<ExtractedFact[]> => {
      if (!this.claudeClient.available) return [];

      const prompt = MemoryFlush.buildExtractionPrompt(text);
      const response = await this.claudeClient.chat({
        model: this.extractionModel,
        messages: [{ role: 'user', content: prompt }],
        max_tokens: 2048,
      });

      return MemoryFlush.parseExtractionResponse(response.content);
    };

    // Build dedup function using Haiku (cheap — classification is structured output)
    const dedupFn = async (existing: string, incoming: string): Promise<DedupDecision> => {
      if (!this.claudeClient.available) return { action: 'ADD' };

      const prompt = MemoryFlush.buildDedupPrompt(existing, incoming);
      const response = await this.claudeClient.chat({
        model: this.extractionModel,
        messages: [{ role: 'user', content: prompt }],
        max_tokens: 256,
      });

      return MemoryFlush.parseDedupResponse(response.content);
    };

    const flush = new MemoryFlush(kg, extractFn, dedupFn);

    return { familyId, db, kg, search, flush };
  }

  private evictLRU(): void {
    let oldestKey: string | null = null;
    let oldestTime = Infinity;

    for (const [key, entry] of this.cache) {
      if (entry.lastAccess < oldestTime) {
        oldestTime = entry.lastAccess;
        oldestKey = key;
      }
    }

    if (oldestKey) {
      const entry = this.cache.get(oldestKey);
      if (entry) {
        try {
          entry.tenant.db.close();
        } catch {
          // Ignore close errors
        }
        this.cache.delete(oldestKey);
      }
    }
  }
}

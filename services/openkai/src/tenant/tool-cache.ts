/**
 * Per-family cache of recent tool-call results.
 *
 * After Claude calls MCP tools, we store the results here. On the next turn,
 * the context builder injects them into the system prompt so Claude doesn't
 * re-call the same tools for follow-up questions.
 *
 * Eviction: results expire after maxAge ms (default 10 minutes) or maxTurns
 * turns without tool use (default 3). This prevents stale data from lingering
 * when the user changes topic.
 */

interface CachedToolResult {
  name: string;
  args: Record<string, unknown>;
  result: string; // Stringified, truncated to keep system prompt manageable
  timestamp: number;
  turnNumber: number;
}

interface FamilyCache {
  results: CachedToolResult[];
  currentTurn: number;
  lastToolUseTurn: number;
}

export interface ToolCacheOptions {
  maxAge: number;       // ms — evict results older than this (default: 10 min)
  maxTurns: number;     // evict if no tool use for this many turns (default: 3)
  maxResultLength: number; // truncate tool results beyond this (default: 2000 chars)
}

const DEFAULTS: ToolCacheOptions = {
  maxAge: 10 * 60 * 1000,
  maxTurns: 3,
  maxResultLength: 2000,
};

export class ToolCache {
  private families: Map<string, FamilyCache> = new Map();
  private options: ToolCacheOptions;

  constructor(options?: Partial<ToolCacheOptions>) {
    this.options = { ...DEFAULTS, ...options };
  }

  /**
   * Record tool results from a completed turn.
   */
  store(familyId: string, results: Array<{ name: string; args: Record<string, unknown>; result: string }>): void {
    const cache = this.getOrCreate(familyId);

    // Replace all cached results with the new ones from this turn
    cache.results = results.map((r) => ({
      name: r.name,
      args: r.args,
      result: r.result.length > this.options.maxResultLength
        ? r.result.slice(0, this.options.maxResultLength) + '\n... (truncated)'
        : r.result,
      timestamp: Date.now(),
      turnNumber: cache.currentTurn,
    }));

    cache.lastToolUseTurn = cache.currentTurn;
  }

  /**
   * Advance the turn counter. Call this at the start of each request.
   */
  advanceTurn(familyId: string): void {
    const cache = this.getOrCreate(familyId);
    cache.currentTurn++;
  }

  /**
   * Get cached tool results for the system prompt.
   * Returns null if cache is empty or expired.
   */
  get(familyId: string): string | null {
    const cache = this.families.get(familyId);
    if (!cache || cache.results.length === 0) return null;

    const now = Date.now();
    const turnsSinceToolUse = cache.currentTurn - cache.lastToolUseTurn;

    // Evict if too old or too many turns without tool use
    if (turnsSinceToolUse > this.options.maxTurns) {
      cache.results = [];
      return null;
    }

    // Evict individually expired results
    cache.results = cache.results.filter((r) => now - r.timestamp < this.options.maxAge);
    if (cache.results.length === 0) return null;

    // Format for system prompt injection
    const lines = cache.results.map((r) => {
      const argsStr = Object.keys(r.args).length > 0
        ? ` (${Object.entries(r.args).map(([k, v]) => `${k}: ${JSON.stringify(v)}`).join(', ')})`
        : '';
      return `### ${r.name}${argsStr}\n\`\`\`\n${r.result}\n\`\`\``;
    });

    return `## Recent Data (from your previous tool calls)\n\nYou already fetched this data — reuse it for follow-up questions instead of calling tools again.\n\n${lines.join('\n\n')}`;
  }

  /**
   * Clear cache for a family (e.g., on session end).
   */
  clear(familyId: string): void {
    this.families.delete(familyId);
  }

  private getOrCreate(familyId: string): FamilyCache {
    let cache = this.families.get(familyId);
    if (!cache) {
      cache = { results: [], currentTurn: 0, lastToolUseTurn: 0 };
      this.families.set(familyId, cache);
    }
    return cache;
  }
}

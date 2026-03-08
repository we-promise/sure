import { createHash } from 'node:crypto';
import { KnowledgeGraph } from './knowledge-graph.js';
import type { Entity, Relation } from './schema.js';
import { ENTITY_TYPES, RELATION_TYPES } from './schema.js';

// --- Helpers ---

function contentHash(text: string): string {
  return createHash('sha256').update(text.trim().toLowerCase()).digest('hex');
}

// --- Interfaces ---

export interface FlushResult {
  entities_created: number;
  relations_created: number;
  entities: Entity[];
}

export interface ExtractedFact {
  name: string;
  type: string;
  content: string;
  confidence: number;
  weight: number;
  relations: Array<{ target_name: string; relation_type: string }>;
}

export type DedupAction = 'ADD' | 'UPDATE' | 'SUPERSEDE' | 'SKIP';

export interface DedupDecision {
  action: DedupAction;
  updated_content?: string;
}

// --- Constants ---

const VALID_ENTITY_TYPES = new Set<string>(ENTITY_TYPES);
const VALID_RELATION_TYPES = new Set<string>(RELATION_TYPES);

// --- MemoryFlush ---

export class MemoryFlush {
  private kg: KnowledgeGraph;
  private extractFn: (text: string) => Promise<ExtractedFact[]>;
  private dedupFn: ((existing: string, incoming: string) => Promise<DedupDecision>) | null;

  constructor(
    kg: KnowledgeGraph,
    extractFn: (text: string) => Promise<ExtractedFact[]>,
    dedupFn?: (existing: string, incoming: string) => Promise<DedupDecision>,
  ) {
    this.kg = kg;
    this.extractFn = extractFn;
    this.dedupFn = dedupFn ?? null;
  }

  async flush(conversationText: string): Promise<FlushResult> {
    const empty: FlushResult = { entities_created: 0, relations_created: 0, entities: [] };

    if (!conversationText.trim()) return empty;

    let facts: ExtractedFact[];
    try {
      facts = await this.extractFn(conversationText);
    } catch (err) {
      console.warn('[memory-flush] Extraction failed:', err);
      return empty;
    }

    if (facts.length === 0) return empty;

    const createdEntities: Entity[] = [];
    const createdRelations: Relation[] = [];
    const nameToId = new Map<string, string>();

    // Phase 1: Create entities
    for (const fact of facts) {
      try {
        const entityType = this.resolveEntityType(fact.type);
        const confidence = this.clamp(fact.confidence, 0, 1);
        const weight = this.clamp(fact.weight, 1, 5);

        const existing = this.kg.findEntityByName(fact.name);

        if (existing) {
          const existingHash = contentHash(existing.content);
          const incomingHash = contentHash(fact.content);
          if (existingHash === incomingHash) {
            nameToId.set(fact.name.toLowerCase(), existing.id);
            continue;
          }
        }

        if (existing && this.dedupFn) {
          const decision = await this.classifyDuplicate(existing, fact);

          switch (decision.action) {
            case 'SKIP':
              nameToId.set(fact.name.toLowerCase(), existing.id);
              continue;

            case 'UPDATE': {
              this.kg.updateEntity(existing.id, {
                content: decision.updated_content ?? fact.content,
                confidence,
                weight: Math.max(existing.weight, weight),
              });
              nameToId.set(fact.name.toLowerCase(), existing.id);
              continue;
            }

            case 'SUPERSEDE': {
              const newEntity = this.kg.createEntity({
                name: fact.name,
                type: entityType,
                content: fact.content,
                source: 'memory-flush',
                confidence,
                weight,
              });
              createdEntities.push(newEntity);
              nameToId.set(fact.name.toLowerCase(), newEntity.id);

              this.kg.updateEntity(existing.id, {
                valid_until: new Date().toISOString(),
              });

              try {
                this.kg.createRelation({
                  from_entity: newEntity.id,
                  to_entity: existing.id,
                  type: 'evolved_from',
                });
              } catch {
                // Non-critical
              }
              continue;
            }

            case 'ADD':
              break;
          }
        }

        const entity = this.kg.createEntity({
          name: fact.name,
          type: entityType,
          content: fact.content,
          source: 'memory-flush',
          confidence,
          weight,
        });

        createdEntities.push(entity);
        nameToId.set(fact.name.toLowerCase(), entity.id);
      } catch (err) {
        console.warn(`[memory-flush] Failed to create entity "${fact.name}":`, err);
      }
    }

    // Phase 2: Create relations
    for (const fact of facts) {
      const sourceId = nameToId.get(fact.name.toLowerCase());
      if (!sourceId) continue;

      for (const rel of fact.relations ?? []) {
        try {
          const targetId =
            nameToId.get(rel.target_name.toLowerCase()) ??
            this.kg.findEntityByName(rel.target_name)?.id ??
            null;

          if (!targetId) continue;

          const relationType = this.resolveRelationType(rel.relation_type);
          const relation = this.kg.createRelation({
            from_entity: sourceId,
            to_entity: targetId,
            type: relationType,
          });

          createdRelations.push(relation);
        } catch (err) {
          console.warn(
            `[memory-flush] Failed to create relation "${fact.name}" -> "${rel.target_name}":`,
            err,
          );
        }
      }
    }

    return {
      entities_created: createdEntities.length,
      relations_created: createdRelations.length,
      entities: createdEntities,
    };
  }

  // --- Extraction prompt for financial domain ---

  static buildExtractionPrompt(text: string): string {
    const summaryInstruction =
      text.length > 300
        ? `
- If this is a substantive conversation, include ONE conversation summary entity:
  - "name": "Conversation: [brief topic]"
  - "type": "fact"
  - "content": 1-3 sentence summary of what was discussed
  - "weight": 3
  - "confidence": 1.0
  Place the summary FIRST in the array.`
        : '';

    return `You are a memory extraction system for a personal finance assistant. Analyze the following conversation and extract structured facts worth remembering long-term.

For each fact, produce a JSON object with these fields:
- "name": short descriptive name (e.g. "User wants to save for house down payment", "User earns $5k/month")
- "type": one of: ${ENTITY_TYPES.map((t) => `"${t}"`).join(', ')}
- "content": the full fact in 1-3 sentences
- "confidence": 0.0 to 1.0 (1.0 = explicitly stated, 0.5 = implied)
- "weight": 2 to 4 (W2 = minor detail, W3 = useful context, W4 = core financial knowledge)
- "relations": array of connections, each with "target_name" and "relation_type" (one of: ${RELATION_TYPES.map((t) => `"${t}"`).join(', ')})

Financial domain guidelines:
- Extract financial goals, spending patterns, income sources, risk preferences, life events
- Do NOT extract raw account numbers, balances, or transaction amounts (the app tracks those)
- DO extract preferences, goals, concerns, life context, and financial personality
- Type guidance: "financial_goal" for goals, "spending_pattern" for habits, "income_source" for income info, "risk_preference" for investment comfort level, "life_event" for milestones, "preference" for general preferences, "fact" for specific knowledge
- Only extract facts worth remembering across sessions. Skip transient information.
- Prefer fewer high-quality facts over many low-quality ones.
- If there are no facts worth extracting, return an empty array.${summaryInstruction}

Respond with ONLY a JSON array. No explanation, no markdown, just the JSON array.

---

Conversation:
${text}`;
  }

  /**
   * Parse Claude's extraction response into validated ExtractedFact objects.
   */
  static parseExtractionResponse(response: string): ExtractedFact[] {
    const jsonStr = extractJsonFromResponse(response);

    let parsed: unknown;
    try {
      parsed = JSON.parse(jsonStr);
    } catch {
      console.warn('[memory-flush] Failed to parse extraction response');
      return [];
    }

    if (!Array.isArray(parsed)) return [];

    const facts: ExtractedFact[] = [];

    for (const item of parsed) {
      if (!isValidFact(item)) continue;

      facts.push({
        name: String(item.name),
        type: String(item.type),
        content: String(item.content),
        confidence: Number(item.confidence),
        weight: Number(item.weight),
        relations: Array.isArray(item.relations)
          ? item.relations
              .filter(
                (r: unknown): r is { target_name: string; relation_type: string } =>
                  typeof r === 'object' &&
                  r !== null &&
                  typeof (r as Record<string, unknown>).target_name === 'string' &&
                  typeof (r as Record<string, unknown>).relation_type === 'string',
              )
              .map((r: { target_name: string; relation_type: string }) => ({
                target_name: r.target_name,
                relation_type: r.relation_type,
              }))
          : [],
      });
    }

    return facts;
  }

  static buildDedupPrompt(existing: string, incoming: string): string {
    return `You are a memory deduplication system. Compare these two knowledge entities and decide what to do.

EXISTING entity (already stored):
${existing}

INCOMING entity (just extracted):
${incoming}

Classify:
- ADD — genuinely new and different
- UPDATE — adds new info to existing (merge them)
- SUPERSEDE — replaces existing (old fact is outdated)
- SKIP — redundant (already known)

Respond with ONLY a JSON object:
{"action": "ADD|UPDATE|SUPERSEDE|SKIP", "updated_content": "merged content if UPDATE, omit otherwise"}`;
  }

  static parseDedupResponse(response: string): DedupDecision {
    const jsonStr = response.match(/\{[\s\S]*\}/)?.[0] ?? response.trim();

    try {
      const parsed = JSON.parse(jsonStr) as Record<string, unknown>;
      const action = String(parsed.action).toUpperCase() as DedupAction;

      if (!['ADD', 'UPDATE', 'SUPERSEDE', 'SKIP'].includes(action)) {
        return { action: 'ADD' };
      }

      return {
        action,
        updated_content:
          action === 'UPDATE' && typeof parsed.updated_content === 'string'
            ? parsed.updated_content
            : undefined,
      };
    } catch {
      return { action: 'ADD' };
    }
  }

  // --- Private helpers ---

  private resolveEntityType(type: string): (typeof ENTITY_TYPES)[number] {
    const normalized = type.toLowerCase().trim();
    if (VALID_ENTITY_TYPES.has(normalized)) {
      return normalized as (typeof ENTITY_TYPES)[number];
    }
    return 'fact';
  }

  private resolveRelationType(type: string): (typeof RELATION_TYPES)[number] {
    const normalized = type.toLowerCase().trim();
    if (VALID_RELATION_TYPES.has(normalized)) {
      return normalized as (typeof RELATION_TYPES)[number];
    }
    return 'relates_to';
  }

  private async classifyDuplicate(
    existing: Entity,
    incoming: ExtractedFact,
  ): Promise<DedupDecision> {
    if (!this.dedupFn) return { action: 'ADD' };

    const existingDesc = `[${existing.type}] ${existing.name}: ${existing.content}`;
    const incomingDesc = `[${incoming.type}] ${incoming.name}: ${incoming.content}`;

    try {
      return await this.dedupFn(existingDesc, incomingDesc);
    } catch {
      return { action: 'ADD' };
    }
  }

  private clamp(value: number, min: number, max: number): number {
    if (!Number.isFinite(value)) return min;
    return Math.max(min, Math.min(max, value));
  }
}

// --- Module-level helpers ---

function extractJsonFromResponse(response: string): string {
  const codeBlockMatch = response.match(/```(?:json)?\s*\n?([\s\S]*?)\n?\s*```/);
  if (codeBlockMatch) return codeBlockMatch[1].trim();

  const arrayMatch = response.match(/\[[\s\S]*\]/);
  if (arrayMatch) return arrayMatch[0];

  return response.trim();
}

function isValidFact(item: unknown): item is Record<string, unknown> {
  if (typeof item !== 'object' || item === null) return false;
  const obj = item as Record<string, unknown>;
  return (
    typeof obj.name === 'string' &&
    obj.name.length > 0 &&
    typeof obj.type === 'string' &&
    typeof obj.content === 'string' &&
    obj.content.length > 0 &&
    typeof obj.confidence === 'number' &&
    typeof obj.weight === 'number'
  );
}

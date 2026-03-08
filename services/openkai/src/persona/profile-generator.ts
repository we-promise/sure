import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { resolve } from 'node:path';
import type { ClaudeClient } from '../intelligence/claude-client.js';
import type { KnowledgeGraph } from '../memory/knowledge-graph.js';

export interface ProfileGeneratorOptions {
  claudeClient: ClaudeClient;
  dataDir: string;
}

/**
 * Generates and updates per-tenant profile files based on KG data.
 * Called periodically or after significant conversations.
 */
export class ProfileGenerator {
  private claude: ClaudeClient;
  private dataDir: string;

  constructor(options: ProfileGeneratorOptions) {
    this.claude = options.claudeClient;
    this.dataDir = options.dataDir;
  }

  /**
   * Regenerate user.md from the knowledge graph entities.
   * This synthesizes all known facts into a coherent profile.
   */
  async regenerateUserProfile(familyId: string, kg: KnowledgeGraph): Promise<void> {
    if (!this.claude.available) return;

    const brainDir = resolve(this.dataDir, 'tenants', familyId, 'brain');
    if (!existsSync(resolve(brainDir, 'user.md'))) return; // Skip if never onboarded

    // Gather all entities relevant to user profile
    const goals = kg.listEntities({ type: 'financial_goal', limit: 10 });
    const patterns = kg.listEntities({ type: 'spending_pattern', limit: 10 });
    const preferences = kg.listEntities({ type: 'preference', limit: 10 });
    const riskPrefs = kg.listEntities({ type: 'risk_preference', limit: 5 });
    const lifeEvents = kg.listEntities({ type: 'life_event', limit: 10 });
    const facts = kg.listEntities({ type: 'fact', limit: 15, minWeight: 2.5 });

    const entities = [...goals, ...patterns, ...preferences, ...riskPrefs, ...lifeEvents, ...facts];

    if (entities.length === 0) return;

    const entityList = entities
      .map((e) => `[${e.type}] ${e.name}: ${e.content}`)
      .join('\n');

    const response = await this.claude.chat({
      messages: [
        {
          role: 'user',
          content: `Based on the following knowledge about a user, generate an updated user profile in markdown.

Include sections for (omit if no data):
- **Name**
- **Financial Goals**
- **Spending Personality**
- **Income & Employment**
- **Life Context**
- **Risk Tolerance**
- **Key Preferences**

Keep it concise. This is loaded into every conversation as context.

---

Known facts:
${entityList}`,
        },
      ],
      max_tokens: 1024,
    });

    mkdirSync(brainDir, { recursive: true });
    writeFileSync(resolve(brainDir, 'user.md'), response.content.trim(), 'utf-8');
  }

  /**
   * Generate self-model.md — the assistant's reflection on its relationship
   * with this user. Based on conversation patterns in the KG.
   */
  async generateSelfModel(familyId: string, kg: KnowledgeGraph): Promise<void> {
    if (!this.claude.available) return;

    const brainDir = resolve(this.dataDir, 'tenants', familyId, 'brain');

    const reflections = kg.listEntities({ type: 'reflection', limit: 10 });
    const selfModels = kg.listEntities({ type: 'self_model', limit: 5 });
    const patterns = kg.listEntities({ type: 'pattern', limit: 10 });

    const entities = [...reflections, ...selfModels, ...patterns];

    if (entities.length < 3) return; // Not enough data to reflect

    const entityList = entities
      .map((e) => `[${e.type}] ${e.name}: ${e.content}`)
      .join('\n');

    const response = await this.claude.chat({
      messages: [
        {
          role: 'user',
          content: `Based on these observations about your interactions with a user, generate a brief self-reflection.

Reflect on:
- How you can best help this specific user
- What communication style works well with them
- Areas where you should be more proactive or careful

Keep it to 3-5 paragraphs. This guides your future behavior with this user.

---

Observations:
${entityList}`,
        },
      ],
      max_tokens: 512,
    });

    mkdirSync(brainDir, { recursive: true });
    writeFileSync(resolve(brainDir, 'self-model.md'), response.content.trim(), 'utf-8');
  }
}

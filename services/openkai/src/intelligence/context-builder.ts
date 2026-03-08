import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';
import type { Entity } from '../memory/schema.js';
import type { ClaudeTool } from './claude-client.js';

export interface ContextBuilderOptions {
  dataDir: string;
  soulTemplatePath: string;
}

export interface ContextLayers {
  familyId: string;
  memories?: Entity[];
  tools?: ClaudeTool[];
  isOnboarding?: boolean;
}

/**
 * Assembles the system prompt from layered context:
 * 1. Identity (soul-template.md)
 * 2. Persona (assistant.md per-tenant)
 * 3. Self-model (self-model.md per-tenant)
 * 4. User profile (user.md per-tenant)
 * 5. Relevant memories from KG
 * 6. Behavioral rules
 * 7. Tool descriptions
 */
export class ContextBuilder {
  private dataDir: string;
  private soulTemplate: string;

  constructor(options: ContextBuilderOptions) {
    this.dataDir = options.dataDir;
    this.soulTemplate = this.loadFile(options.soulTemplatePath) ?? '';
  }

  buildSystemPrompt(layers: ContextLayers): string {
    const sections: string[] = [];

    // 1. Identity
    if (this.soulTemplate) {
      sections.push(this.soulTemplate);
    }

    const brainDir = this.tenantBrainDir(layers.familyId);

    // 2. Persona (assistant name + personality)
    const assistantMd = this.loadFile(resolve(brainDir, 'assistant.md'));
    if (assistantMd) {
      sections.push(`## Your Persona\n\n${assistantMd}`);
    }

    // 3. Self-model
    const selfModel = this.loadFile(resolve(brainDir, 'self-model.md'));
    if (selfModel) {
      sections.push(`## Self-Reflection\n\n${selfModel}`);
    }

    // 4. User profile
    const userMd = this.loadFile(resolve(brainDir, 'user.md'));
    if (userMd) {
      sections.push(`## About This User\n\n${userMd}`);
    }

    // 5. Relevant memories
    if (layers.memories && layers.memories.length > 0) {
      const memoryLines = layers.memories.map(
        (m) => `- [${m.type}] ${m.name}: ${m.content}`,
      );
      sections.push(
        `## Relevant Memories\n\nThings you remember about this user and their finances:\n${memoryLines.join('\n')}`,
      );
    }

    // 6. Behavioral rules
    sections.push(this.buildBehavioralRules(layers.isOnboarding));

    // 7. Tool descriptions
    if (layers.tools && layers.tools.length > 0 && !layers.isOnboarding) {
      const toolDescs = layers.tools.map(
        (t) => `- **${t.name}**: ${t.description}`,
      );
      sections.push(
        `## Available Financial Data Tools\n\nYou can request data from the user's finance app using these tools:\n${toolDescs.join('\n')}\n\nUse tools when you need specific financial data to answer the user's question. Don't guess — look it up.`,
      );
    }

    return sections.join('\n\n---\n\n');
  }

  /**
   * Check if a tenant has completed onboarding (user.md exists)
   */
  hasUserProfile(familyId: string): boolean {
    const brainDir = this.tenantBrainDir(familyId);
    return existsSync(resolve(brainDir, 'user.md'));
  }

  tenantBrainDir(familyId: string): string {
    return resolve(this.dataDir, 'tenants', familyId, 'brain');
  }

  tenantDataDir(familyId: string): string {
    return resolve(this.dataDir, 'tenants', familyId);
  }

  private buildBehavioralRules(isOnboarding?: boolean): string {
    if (isOnboarding) {
      return `## Behavioral Rules

- This is the user's first session. Your goal is to get to know them.
- Ask one question at a time. Be warm, curious, and conversational.
- Do NOT call any financial data tools during onboarding.
- Learn their name, financial goals, spending personality, and upcoming life events.
- Let the user name you — suggest a name if they can't decide.
- Keep responses concise and friendly. No filler phrases.
- After learning enough, summarize what you've learned and express excitement to help.`;
    }

    return `## Behavioral Rules

- Provide ONLY the most important numbers and insights.
- Eliminate unnecessary words and context.
- Ask follow-up questions to keep the conversation going.
- Do NOT add introductions or conclusions.
- Do NOT apologize or explain limitations.
- Format all responses in markdown.
- When discussing money, use the numbers from the data — never guess.
- Connect spending patterns to the user's stated goals when relevant.
- Be proactive: if you notice something interesting in the data, mention it.
- Focus on educating the user about personal finance using their own data.
- Do not tell the user to buy or sell specific financial products.
- Use available tools to get data. Don't make assumptions.
- Current date: ${new Date().toISOString().split('T')[0]}`;
  }

  private loadFile(path: string): string | null {
    try {
      if (!existsSync(path)) return null;
      return readFileSync(path, 'utf-8').trim();
    } catch {
      return null;
    }
  }
}

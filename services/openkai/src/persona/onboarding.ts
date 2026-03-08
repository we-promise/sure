import { writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { resolve } from 'node:path';
import type { ContextBuilder, ContextLayers } from '../intelligence/context-builder.js';
import type { TenantContext } from '../tenant/manager.js';
import type { ClaudeClient } from '../intelligence/claude-client.js';

export interface OnboardingOptions {
  claudeClient: ClaudeClient;
  dataDir: string;
}

/**
 * Handles first-session detection and profile generation.
 * When a user chats for the first time, the assistant runs an
 * onboarding conversation to learn about them before calling tools.
 */
export class Onboarding {
  private claude: ClaudeClient;
  private dataDir: string;

  constructor(options: OnboardingOptions) {
    this.claude = options.claudeClient;
    this.dataDir = options.dataDir;
  }

  /**
   * Build the system prompt for an onboarding session.
   */
  buildOnboardingPrompt(contextBuilder: ContextBuilder, familyId: string): string {
    return contextBuilder.buildSystemPrompt({
      familyId,
      isOnboarding: true,
    });
  }

  /**
   * After enough conversation, generate user.md and assistant.md.
   * Called fire-and-forget after each onboarding response.
   *
   * Heuristic: generate profile after 4+ user messages (enough info gathered).
   */
  async maybeGenerateProfile(
    familyId: string,
    messages: Array<{ role: string; content: string }>,
    tenant: TenantContext,
    contextBuilder: ContextBuilder,
  ): Promise<boolean> {
    const userMessages = messages.filter((m) => m.role === 'user');
    if (userMessages.length < 4) return false;

    // Already generated?
    if (contextBuilder.hasUserProfile(familyId)) return false;

    try {
      await this.generateProfile(familyId, messages, tenant);
      return true;
    } catch (err) {
      console.warn(`[onboarding] Profile generation failed for ${familyId}:`, err);
      return false;
    }
  }

  private async generateProfile(
    familyId: string,
    messages: Array<{ role: string; content: string }>,
    tenant: TenantContext,
  ): Promise<void> {
    if (!this.claude.available) return;

    const conversation = messages
      .map((m) => `${m.role}: ${m.content}`)
      .join('\n');

    // Generate user.md
    const userProfileResponse = await this.claude.chat({
      messages: [
        {
          role: 'user',
          content: `Based on the following onboarding conversation with a new user of a personal finance app, generate a concise user profile in markdown format.

Include sections for:
- **Name** (if shared)
- **Financial Goals** (top priorities)
- **Spending Personality** (saver/spender/balanced, any specific habits)
- **Life Context** (stage of life, household composition, upcoming events)
- **Key Preferences** (communication style, what matters to them)

Keep it concise — this will be loaded into every conversation as context.
If information wasn't shared, omit that section. Don't fabricate details.

---

Conversation:
${conversation}`,
        },
      ],
      max_tokens: 1024,
    });

    // Extract assistant name from conversation
    const assistantNameResponse = await this.claude.chat({
      messages: [
        {
          role: 'user',
          content: `From this onboarding conversation, extract the name the user chose for their financial assistant.
If the user didn't choose a name, respond with just "Kai" (the default).
Respond with ONLY the name, nothing else.

Conversation:
${conversation}`,
        },
      ],
      max_tokens: 50,
    });

    const assistantName = assistantNameResponse.content.trim() || 'Kai';
    const brainDir = resolve(this.dataDir, 'tenants', familyId, 'brain');
    mkdirSync(brainDir, { recursive: true });

    // Write user.md
    writeFileSync(
      resolve(brainDir, 'user.md'),
      userProfileResponse.content.trim(),
      'utf-8',
    );

    // Write assistant.md
    const assistantMd = `# ${assistantName}

Created: ${new Date().toISOString().split('T')[0]}
Family: ${familyId}

${assistantName} is a personal financial assistant powered by OpenKai's memory system.
Born from the onboarding conversation, ${assistantName} grows with every interaction.
`;

    writeFileSync(resolve(brainDir, 'assistant.md'), assistantMd, 'utf-8');

    // Flush conversation facts to KG
    await tenant.flush.flush(conversation);

    console.log(`[onboarding] Generated profile for family ${familyId}: assistant "${assistantName}"`);
  }
}

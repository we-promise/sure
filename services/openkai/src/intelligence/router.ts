import type { Config, RoutingConfig } from '../config.js';
import { ClaudeClient } from './claude-client.js';

export type Complexity = 'moderate' | 'complex';

export interface RouteResult {
  model: string;
  complexity: Complexity;
  reason: string;
}

export interface RouterOptions {
  config: Config;
}

// Financial complexity signals — trigger upgrade to Opus
const COMPLEX_SIGNALS = [
  'should i',
  'refinance',
  'invest',
  'investing',
  'investment strategy',
  'tax strategy',
  'tax planning',
  'forecast',
  'plan for',
  'retirement',
  'mortgage',
  'estate planning',
  'asset allocation',
  'risk tolerance',
  'financial plan',
  'long term',
  'long-term',
  'compare options',
  'pros and cons',
  'trade-off',
  'tradeoff',
  'what are the implications',
];

export class ModelRouter {
  private claude: ClaudeClient;
  private routing: RoutingConfig;

  constructor(options: RouterOptions) {
    this.claude = new ClaudeClient({
      config: options.config.claude,
      pricing: options.config.pricing,
    });
    this.routing = options.config.routing;
  }

  get claudeClient(): ClaudeClient {
    return this.claude;
  }

  /**
   * Determine which model to use based on the conversation.
   * Floor is Sonnet — Haiku is too weak for financial persona.
   */
  route(messages: Array<{ role: string; content: string }>): RouteResult {
    if (!this.claude.available) {
      throw new Error(
        'Assistant is offline: Claude API not configured.',
      );
    }

    if (this.claude.budgetExceeded) {
      throw new Error(
        'Assistant is offline: daily budget exceeded. Resets at midnight.',
      );
    }

    const complexity = this.classifyComplexity(messages);
    const model = complexity === 'complex' ? this.routing.complex : this.routing.moderate;

    return {
      model,
      complexity,
      reason: `${complexity} → ${model}`,
    };
  }

  classifyComplexity(
    messages: Array<{ role: string; content: string }>,
  ): Complexity {
    const lastMessage = messages[messages.length - 1]?.content ?? '';
    const lower = lastMessage.toLowerCase();
    const wordCount = lastMessage.split(/\s+/).length;

    if (COMPLEX_SIGNALS.some((s) => lower.includes(s)) || wordCount > 100) {
      return 'complex';
    }

    return 'moderate';
  }
}

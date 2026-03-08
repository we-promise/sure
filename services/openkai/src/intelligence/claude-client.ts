import Anthropic from '@anthropic-ai/sdk';
import { HttpsProxyAgent } from 'https-proxy-agent';
import type { ClaudeConfig, PricingEntry } from '../config.js';

// --- Interfaces ---

export interface ClaudeClientOptions {
  config: ClaudeConfig;
  pricing: Record<string, PricingEntry>;
}

export interface ClaudeChatRequest {
  model?: string;
  messages: Array<{ role: 'user' | 'assistant'; content: string }>;
  system?: string;
  max_tokens?: number;
}

export interface ClaudeTool {
  name: string;
  description: string;
  input_schema: {
    type: 'object';
    properties?: Record<string, unknown>;
    required?: string[];
    [key: string]: unknown;
  };
}

export interface ClaudeToolUseRequest extends ClaudeChatRequest {
  tools: ClaudeTool[];
}

export interface ClaudeChatResponse {
  content: string;
  model: string;
  usage: {
    input_tokens: number;
    output_tokens: number;
  };
  stop_reason: string | null;
}

export interface ToolUseBlock {
  id: string;
  name: string;
  input: Record<string, unknown>;
}

export interface ClaudeToolUseResponse {
  content: string;
  model: string;
  usage: {
    input_tokens: number;
    output_tokens: number;
  };
  stop_reason: string | null;
  tool_use: ToolUseBlock[];
}

interface BudgetState {
  spent_today_usd: number;
  last_reset: string; // ISO date (YYYY-MM-DD)
}

export interface FamilyBudget {
  spent: number;
  limit: number;
  remaining: number;
}

// --- Client ---

export class ClaudeClient {
  private client: Anthropic | null = null;
  private config: ClaudeConfig;
  private pricing: Record<string, PricingEntry>;
  private globalBudget: BudgetState;
  private familyBudgets: Map<string, BudgetState> = new Map();

  constructor(options: ClaudeClientOptions) {
    this.config = options.config;
    this.pricing = options.pricing;
    this.globalBudget = {
      spent_today_usd: 0,
      last_reset: new Date().toISOString().split('T')[0],
    };

    if (this.config.api_key) {
      const proxyUrl = process.env.HTTPS_PROXY;
      this.client = new Anthropic({
        apiKey: this.config.api_key,
        ...(proxyUrl && { httpAgent: new HttpsProxyAgent(proxyUrl) }),
      });
    }
  }

  get available(): boolean {
    return this.client !== null;
  }

  get budgetRemaining(): number {
    this.resetBudgetIfNewDay();
    return this.config.daily_budget_usd - this.globalBudget.spent_today_usd;
  }

  get budgetExceeded(): boolean {
    return this.budgetRemaining <= 0;
  }

  familyBudgetExceeded(familyId: string): boolean {
    this.resetBudgetIfNewDay();
    const fb = this.familyBudgets.get(familyId);
    if (!fb) return false;
    return fb.spent_today_usd >= this.config.per_family_daily_budget_usd;
  }

  getFamilyBudget(familyId: string): FamilyBudget {
    this.resetBudgetIfNewDay();
    const fb = this.familyBudgets.get(familyId);
    const spent = fb?.spent_today_usd ?? 0;
    return {
      spent,
      limit: this.config.per_family_daily_budget_usd,
      remaining: Math.max(0, this.config.per_family_daily_budget_usd - spent),
    };
  }

  getSpendToday(): { spent: number; budget: number; remaining: number } {
    this.resetBudgetIfNewDay();
    return {
      spent: this.globalBudget.spent_today_usd,
      budget: this.config.daily_budget_usd,
      remaining: this.budgetRemaining,
    };
  }

  /**
   * Non-streaming chat for internal use (extraction, dedup, etc.)
   */
  async chat(request: ClaudeChatRequest): Promise<ClaudeChatResponse> {
    if (!this.client) {
      throw new Error('Claude API not available: no API key configured');
    }

    this.checkBudget();

    const model = request.model ?? this.config.default_model;

    const response = await this.client.messages.create({
      model,
      max_tokens: request.max_tokens ?? 4096,
      system: request.system,
      messages: request.messages,
    });

    const textContent = response.content
      .filter((block): block is Anthropic.TextBlock => block.type === 'text')
      .map((block) => block.text)
      .join('');

    this.trackCost(model, response.usage);

    return {
      content: textContent,
      model: response.model,
      usage: {
        input_tokens: response.usage.input_tokens,
        output_tokens: response.usage.output_tokens,
      },
      stop_reason: response.stop_reason,
    };
  }

  /**
   * Stream a chat response, calling onToken for each text chunk.
   * Returns the final complete response.
   */
  async chatStream(
    request: ClaudeChatRequest,
    onToken: (token: string) => void,
    familyId?: string,
  ): Promise<ClaudeChatResponse> {
    if (!this.client) {
      throw new Error('Claude API not available: no API key configured');
    }

    this.checkBudget(familyId);

    const model = request.model ?? this.config.default_model;

    const stream = this.client.messages.stream({
      model,
      max_tokens: request.max_tokens ?? 4096,
      system: request.system,
      messages: request.messages,
    });

    let fullText = '';

    stream.on('text', (text) => {
      fullText += text;
      onToken(text);
    });

    const finalMessage = await stream.finalMessage();

    this.trackCost(model, finalMessage.usage, familyId);

    return {
      content: fullText,
      model: finalMessage.model,
      usage: {
        input_tokens: finalMessage.usage.input_tokens,
        output_tokens: finalMessage.usage.output_tokens,
      },
      stop_reason: finalMessage.stop_reason,
    };
  }

  /**
   * Stream with tool use support. On tool_use stop reason, returns the
   * tool use blocks instead of streaming further. Caller handles tool
   * execution and calls chatStreamToolResult to continue.
   */
  async chatStreamWithTools(
    request: ClaudeToolUseRequest,
    onToken: (token: string) => void,
    familyId?: string,
  ): Promise<ClaudeToolUseResponse> {
    if (!this.client) {
      throw new Error('Claude API not available: no API key configured');
    }

    this.checkBudget(familyId);

    const model = request.model ?? this.config.default_model;

    const stream = this.client.messages.stream({
      model,
      max_tokens: request.max_tokens ?? 4096,
      system: request.system,
      messages: request.messages,
      tools: request.tools,
    });

    let fullText = '';
    const toolUseBlocks: ToolUseBlock[] = [];

    stream.on('text', (text) => {
      fullText += text;
      onToken(text);
    });

    const finalMessage = await stream.finalMessage();

    // Extract tool_use blocks from the response
    for (const block of finalMessage.content) {
      if (block.type === 'tool_use') {
        toolUseBlocks.push({
          id: block.id,
          name: block.name,
          input: block.input as Record<string, unknown>,
        });
      }
    }

    this.trackCost(model, finalMessage.usage, familyId);

    return {
      content: fullText,
      model: finalMessage.model,
      usage: {
        input_tokens: finalMessage.usage.input_tokens,
        output_tokens: finalMessage.usage.output_tokens,
      },
      stop_reason: finalMessage.stop_reason,
      tool_use: toolUseBlocks,
    };
  }

  /**
   * Continue streaming after tool use — sends tool results back to Claude.
   */
  async chatStreamToolResult(
    request: ClaudeToolUseRequest,
    previousMessages: Anthropic.Messages.MessageParam[],
    toolResults: Array<{ tool_use_id: string; content: string }>,
    onToken: (token: string) => void,
    familyId?: string,
  ): Promise<ClaudeChatResponse> {
    if (!this.client) {
      throw new Error('Claude API not available: no API key configured');
    }

    const model = request.model ?? this.config.default_model;

    // Build messages: previous + tool results
    const messages: Anthropic.Messages.MessageParam[] = [
      ...previousMessages,
      {
        role: 'user',
        content: toolResults.map((r) => ({
          type: 'tool_result' as const,
          tool_use_id: r.tool_use_id,
          content: r.content,
        })),
      },
    ];

    const stream = this.client.messages.stream({
      model,
      max_tokens: request.max_tokens ?? 4096,
      system: request.system,
      messages,
      tools: request.tools,
    });

    let fullText = '';

    stream.on('text', (text) => {
      fullText += text;
      onToken(text);
    });

    const finalMessage = await stream.finalMessage();

    this.trackCost(model, finalMessage.usage, familyId);

    return {
      content: fullText,
      model: finalMessage.model,
      usage: {
        input_tokens: finalMessage.usage.input_tokens,
        output_tokens: finalMessage.usage.output_tokens,
      },
      stop_reason: finalMessage.stop_reason,
    };
  }

  // --- Budget tracking ---

  private checkBudget(familyId?: string): void {
    this.resetBudgetIfNewDay();

    if (this.budgetExceeded) {
      throw new Error(
        `Daily budget exceeded: $${this.globalBudget.spent_today_usd.toFixed(2)} / $${this.config.daily_budget_usd.toFixed(2)}`,
      );
    }

    if (familyId && this.familyBudgetExceeded(familyId)) {
      const fb = this.familyBudgets.get(familyId)!;
      throw new Error(
        `Family daily budget exceeded: $${fb.spent_today_usd.toFixed(2)} / $${this.config.per_family_daily_budget_usd.toFixed(2)}`,
      );
    }
  }

  private trackCost(
    model: string,
    usage: { input_tokens: number; output_tokens: number },
    familyId?: string,
  ): void {
    const p = this.pricing[model] ?? { input: 3, output: 15 };
    const cost = (usage.input_tokens * p.input + usage.output_tokens * p.output) / 1_000_000;

    this.globalBudget.spent_today_usd += cost;

    if (familyId) {
      const fb = this.familyBudgets.get(familyId) ?? {
        spent_today_usd: 0,
        last_reset: new Date().toISOString().split('T')[0],
      };
      fb.spent_today_usd += cost;
      this.familyBudgets.set(familyId, fb);
    }
  }

  private resetBudgetIfNewDay(): void {
    const today = new Date().toISOString().split('T')[0];

    if (today !== this.globalBudget.last_reset) {
      this.globalBudget.spent_today_usd = 0;
      this.globalBudget.last_reset = today;
      this.familyBudgets.clear();
    }
  }
}

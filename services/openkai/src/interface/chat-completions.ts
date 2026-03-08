import { randomUUID } from 'node:crypto';
import type { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import type { ModelRouter } from '../intelligence/router.js';
import type { ContextBuilder, ContextLayers } from '../intelligence/context-builder.js';
import type { TenantManager, TenantContext } from '../tenant/manager.js';
import type { SureClient } from '../mcp/sure-client.js';
import type { ToolMapper } from '../mcp/tool-mapper.js';
import type { Onboarding } from '../persona/onboarding.js';
import type { Entity } from '../memory/schema.js';
import type { ClaudeTool } from '../intelligence/claude-client.js';
import type { ToolCache } from '../tenant/tool-cache.js';
import type Anthropic from '@anthropic-ai/sdk';

interface ChatCompletionBody {
  model?: string;
  messages: Array<{ role: 'user' | 'assistant'; content: string }>;
  stream?: boolean;
  user?: string; // "sure-family-<id>"
}

interface Dependencies {
  router: ModelRouter;
  contextBuilder: ContextBuilder;
  tenantManager: TenantManager | null;
  sureClient: SureClient | null;
  toolMapper: ToolMapper | null;
  toolCache: ToolCache;
  onboarding: Onboarding | null;
  authToken: string;
}

/**
 * SSE endpoint matching Sure's External::Client contract.
 *
 * Response format:
 * data: {"id":"chatcmpl-<uuid>","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"..."},"finish_reason":null}],"model":"claude-sonnet-4-20250514"}\n\n
 * ...
 * data: [DONE]\n\n
 */
export function registerChatCompletionsRoute(
  app: FastifyInstance,
  deps: Dependencies,
): void {
  app.post('/v1/chat/completions', async (request: FastifyRequest, reply: FastifyReply) => {
    // Auth check
    const authHeader = request.headers.authorization;
    const token = authHeader?.replace(/^Bearer\s+/i, '');

    if (!token || token !== deps.authToken) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const body = request.body as ChatCompletionBody;

    if (!body.messages || body.messages.length === 0) {
      return reply.code(400).send({ error: 'messages is required' });
    }

    // Extract family ID from the user field: "sure-family-<id>"
    const familyId = extractFamilyId(body.user);
    if (!familyId) {
      return reply.code(400).send({ error: 'user field must be "sure-family-<id>"' });
    }

    // Check per-family budget
    if (deps.router.claudeClient.familyBudgetExceeded(familyId)) {
      const fb = deps.router.claudeClient.getFamilyBudget(familyId);
      return reply.code(429).send({
        error: `Daily budget exceeded ($${fb.spent.toFixed(2)} / $${fb.limit.toFixed(2)}). Resets at midnight.`,
      });
    }

    const completionId = `chatcmpl-${randomUUID()}`;

    // Set SSE headers
    reply.raw.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
      'X-Accel-Buffering': 'no',
    });

    try {
      await handleChat(completionId, familyId, body, deps, reply);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : 'Internal server error';
      request.log.error({ err }, 'Chat completion error');

      // Send error as SSE chunk if we haven't closed yet
      sendSSE(reply, completionId, 'unknown', {
        content: `I'm sorry, I encountered an error: ${message}`,
        finish_reason: null,
      });
      sendSSE(reply, completionId, 'unknown', { content: null, finish_reason: 'stop' });
      reply.raw.write('data: [DONE]\n\n');
      reply.raw.end();
    }
  });
}

async function handleChat(
  completionId: string,
  familyId: string,
  body: ChatCompletionBody,
  deps: Dependencies,
  reply: FastifyReply,
): Promise<void> {
  const { router, contextBuilder, tenantManager, sureClient, toolMapper, toolCache, onboarding } = deps;

  // Advance the tool cache turn counter for this family
  toolCache.advanceTurn(familyId);

  // Route to determine model
  const route = router.route(body.messages);
  let resolvedModel = route.model;

  // Load tenant context if available
  let tenant: TenantContext | null = null;
  if (tenantManager) {
    tenant = await tenantManager.getTenant(familyId);
  }

  // Check if this is an onboarding session
  const isOnboarding = onboarding && !contextBuilder.hasUserProfile(familyId);

  // Search for relevant memories
  let memories: Entity[] = [];
  if (tenant && !isOnboarding) {
    const lastUserMsg = body.messages[body.messages.length - 1]?.content ?? '';
    try {
      const results = tenant.search.bm25Search(lastUserMsg, 5, undefined, 2.0);
      if (results.length > 0) {
        const entityIds = results.map((r) => r.entity_id);
        memories = entityIds
          .map((id) => tenant!.kg.getEntity(id))
          .filter((e): e is Entity => e !== null);
      }
    } catch {
      // Non-critical — continue without memories
    }
  }

  // Build tools from MCP
  let claudeTools: ClaudeTool[] = [];
  if (toolMapper && !isOnboarding) {
    claudeTools = toolMapper.getClaudeTools();
  }

  // Build system prompt
  const contextLayers: ContextLayers = {
    familyId,
    memories,
    tools: claudeTools,
    isOnboarding: isOnboarding ?? false,
  };

  // If onboarding, inject the onboarding system prompt
  let systemPrompt: string;
  if (isOnboarding && onboarding) {
    systemPrompt = onboarding.buildOnboardingPrompt(contextBuilder, familyId);
  } else {
    systemPrompt = contextBuilder.buildSystemPrompt(contextLayers);
  }

  // Inject cached tool results from previous turns (so Claude doesn't re-call tools)
  const cachedData = toolCache.get(familyId);
  if (cachedData) {
    systemPrompt += '\n\n' + cachedData;
  }

  // Stream the response — collect full assistant text for memory flush
  let assistantText = '';
  let usedTools = false;

  const onToken = (text: string) => {
    assistantText += text;
    sendSSE(reply, completionId, resolvedModel, { content: text, finish_reason: null });
  };

  if (claudeTools.length > 0 && !isOnboarding) {
    // Chat with tool use support
    const toolResponse = await router.claudeClient.chatStreamWithTools(
      {
        model: resolvedModel,
        system: systemPrompt,
        messages: body.messages.map((m) => ({
          role: m.role as 'user' | 'assistant',
          content: m.content,
        })),
        tools: claudeTools,
      },
      onToken,
      familyId,
    );

    resolvedModel = toolResponse.model;

    // Handle tool use — one round-trip max (matches Sure's builtin)
    if (toolResponse.tool_use.length > 0 && sureClient) {
      usedTools = true;

      // Execute tools via MCP
      const toolResults: Array<{ tool_use_id: string; content: string }> = [];

      for (const toolUse of toolResponse.tool_use) {
        try {
          const result = await sureClient.callTool(toolUse.name, toolUse.input as Record<string, unknown>);
          toolResults.push({
            tool_use_id: toolUse.id,
            content: JSON.stringify(result),
          });
        } catch (err: unknown) {
          const msg = err instanceof Error ? err.message : 'Tool call failed';
          toolResults.push({
            tool_use_id: toolUse.id,
            content: JSON.stringify({ error: msg }),
          });
        }
      }

      // Cache tool results for follow-up turns
      toolCache.store(
        familyId,
        toolResponse.tool_use.map((tu, i) => ({
          name: tu.name,
          args: tu.input as Record<string, unknown>,
          result: toolResults[i].content,
        })),
      );

      // Build the messages including the assistant's tool_use response
      const prevMessages: Anthropic.Messages.MessageParam[] = [
        ...body.messages.map((m) => ({
          role: m.role as 'user' | 'assistant',
          content: m.content,
        })),
        {
          role: 'assistant' as const,
          content: [
            // Include any text content before tool use
            ...(toolResponse.content ? [{ type: 'text' as const, text: toolResponse.content }] : []),
            // Include tool use blocks
            ...toolResponse.tool_use.map((tu) => ({
              type: 'tool_use' as const,
              id: tu.id,
              name: tu.name,
              input: tu.input,
            })),
          ],
        },
      ];

      // Continue with tool results
      const followUp = await router.claudeClient.chatStreamToolResult(
        {
          model: resolvedModel,
          system: systemPrompt,
          messages: [],
          tools: claudeTools,
        },
        prevMessages,
        toolResults,
        onToken,
        familyId,
      );

      resolvedModel = followUp.model;
    }
  } else {
    // Simple streaming (no tools — onboarding or no MCP)
    const response = await router.claudeClient.chatStream(
      {
        model: resolvedModel,
        system: systemPrompt,
        messages: body.messages.map((m) => ({
          role: m.role as 'user' | 'assistant',
          content: m.content,
        })),
      },
      onToken,
      familyId,
    );

    resolvedModel = response.model;
  }

  // Send finish
  sendSSE(reply, completionId, resolvedModel, { content: null, finish_reason: 'stop' });
  reply.raw.write('data: [DONE]\n\n');
  reply.raw.end();

  // Fire-and-forget: memory flush after response completes.
  // Flush the FULL conversation turn (user + assistant response).
  // The assistant's response often contains insights worth remembering
  // ("you spent 30% more on dining" → spending_pattern entity).
  if (tenant && !isOnboarding) {
    const lastUserMsg = body.messages[body.messages.length - 1]?.content ?? '';
    const userWordCount = lastUserMsg.split(/\s+/).length;

    // Gate: only flush substantive turns.
    // Tool-use turns are always substantive (real financial Q&A).
    // Otherwise require >10 words (skip "hi", "thanks", "ok").
    const shouldFlush = usedTools || userWordCount > 10;

    if (shouldFlush && assistantText.length > 0) {
      const turnText = `User: ${lastUserMsg}\n\nAssistant: ${assistantText}`;
      tenant.flush
        .flush(turnText)
        .catch((err) => console.warn('[memory-flush] Post-response flush failed:', err));
    }
  }

  // Fire-and-forget: onboarding profile generation
  if (isOnboarding && onboarding && tenant) {
    onboarding
      .maybeGenerateProfile(familyId, body.messages, tenant, contextBuilder)
      .catch((err) => console.warn('[onboarding] Profile generation failed:', err));
  }
}

function sendSSE(
  reply: FastifyReply,
  id: string,
  model: string,
  delta: { content: string | null; finish_reason: string | null },
): void {
  const chunk = {
    id,
    object: 'chat.completion.chunk',
    choices: [
      {
        index: 0,
        delta: delta.content !== null ? { content: delta.content } : {},
        finish_reason: delta.finish_reason,
      },
    ],
    model,
  };

  reply.raw.write(`data: ${JSON.stringify(chunk)}\n\n`);
}

function extractFamilyId(user?: string): string | null {
  if (!user) return null;
  const match = user.match(/^sure-family-(.+)$/);
  return match?.[1] ?? null;
}

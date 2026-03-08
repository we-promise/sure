import Fastify from 'fastify';
import { resolve } from 'node:path';
import { loadConfig, getProjectRoot } from './config.js';
import { ModelRouter } from './intelligence/router.js';
import { ContextBuilder } from './intelligence/context-builder.js';
import { TenantManager } from './tenant/manager.js';
import { SureClient } from './mcp/sure-client.js';
import { ToolMapper } from './mcp/tool-mapper.js';

import { Onboarding } from './persona/onboarding.js';
import { ToolCache } from './tenant/tool-cache.js';
import { registerHealthRoutes } from './interface/health.js';
import { registerChatCompletionsRoute } from './interface/chat-completions.js';

async function main(): Promise<void> {
  const config = loadConfig();
  const log = config.daemon.log_level;

  console.log(`[openkai-sure] Starting ${config.daemon.name} v${config.daemon.version}`);
  console.log(`[openkai-sure] Log level: ${log}`);
  console.log(`[openkai-sure] Data dir: ${config.memory.data_dir}`);

  // --- Core services ---

  const router = new ModelRouter({ config });

  const contextBuilder = new ContextBuilder({
    dataDir: config.memory.data_dir,
    soulTemplatePath: resolve(getProjectRoot(), 'config/soul-template.md'),
  });

  const tenantManager = new TenantManager({
    memoryConfig: config.memory,
    claudeClient: router.claudeClient,
    extractionModel: config.claude.extraction_model,
  });

  // --- Sure REST API client (financial data) ---

  let sureClient: SureClient | null = null;
  let toolMapper: ToolMapper | null = null;

  if (config.sureApi.apiKey) {
    sureClient = new SureClient(config.sureApi);
    toolMapper = new ToolMapper();

    try {
      await sureClient.initialize();
      console.log(`[openkai-sure] Sure API connected: ${toolMapper.getClaudeTools().length} tools available`);
    } catch (err) {
      console.warn('[openkai-sure] Sure API connection failed — tools unavailable:', err);
      sureClient = null;
      toolMapper = null;
    }
  } else {
    console.warn('[openkai-sure] SURE_API_KEY not set — financial tools disabled');
  }

  // --- Tool result cache (survives across turns within a session) ---

  const toolCache = new ToolCache();

  // --- Onboarding ---

  const onboarding = new Onboarding({
    claudeClient: router.claudeClient,
    dataDir: config.memory.data_dir,
  });

  // --- HTTP server ---

  const app = Fastify({
    logger: {
      level: log,
    },
  });

  // Parse JSON bodies
  app.addContentTypeParser('application/json', { parseAs: 'string' }, (_req, body, done) => {
    try {
      done(null, JSON.parse(body as string));
    } catch (err) {
      done(err as Error, undefined);
    }
  });

  // Register routes
  registerHealthRoutes(app, router);

  const authToken = process.env.OPENKAI_AUTH_TOKEN ?? '';
  if (!authToken) {
    console.warn('[openkai-sure] OPENKAI_AUTH_TOKEN not set — endpoint is unprotected!');
  }

  registerChatCompletionsRoute(app, {
    router,
    contextBuilder,
    tenantManager,
    sureClient,
    toolMapper,
    toolCache,
    onboarding,
    authToken,
  });

  // --- Start ---

  const host = config.api.host;
  const port = config.api.port;

  await app.listen({ host, port });
  console.log(`[openkai-sure] Listening on http://${host}:${port}`);
  console.log(`[openkai-sure] Claude: ${router.claudeClient.available ? 'available' : 'NOT CONFIGURED'}`);
  console.log(`[openkai-sure] Sure API: ${sureClient ? 'connected' : 'disabled'}`);

  // Graceful shutdown
  const shutdown = async (signal: string) => {
    console.log(`[openkai-sure] ${signal} received, shutting down...`);
    tenantManager.closeAll();
    await app.close();
    process.exit(0);
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

main().catch((err) => {
  console.error('[openkai-sure] Fatal error:', err);
  process.exit(1);
});

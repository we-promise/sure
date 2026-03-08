import type { FastifyInstance } from 'fastify';
import type { ModelRouter } from '../intelligence/router.js';

export function registerHealthRoutes(app: FastifyInstance, router: ModelRouter): void {
  app.get('/health', async (_request, reply) => {
    const spend = router.claudeClient.getSpendToday();

    return reply.send({
      status: 'ok',
      service: 'openkai-sure',
      claude: {
        available: router.claudeClient.available,
        budget: {
          spent_today_usd: parseFloat(spend.spent.toFixed(4)),
          daily_limit_usd: spend.budget,
          remaining_usd: parseFloat(spend.remaining.toFixed(4)),
        },
      },
      timestamp: new Date().toISOString(),
    });
  });
}

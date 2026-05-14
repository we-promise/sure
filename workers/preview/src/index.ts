import { Container } from "@cloudflare/containers";

interface Env {
  RAILS_CONTAINER: DurableObjectNamespace<RailsContainer>;
}

const DIAGNOSTICS_KEY = "preview-diagnostics";
const DIAGNOSTICS_HISTORY_KEY = "preview-diagnostics-history";

export class RailsContainer extends Container {
  defaultPort = 3000;
  pingEndpoint = "container/up";
  sleepAfter = "30m";

  get runtimeContainer() {
    return this.ctx.container!;
  }

  async recordDiagnostic(payload: Record<string, unknown>): Promise<void> {
    const diagnostic = {
      ...payload,
      state: await this.getState(),
    };

    await this.ctx.storage.put(DIAGNOSTICS_KEY, diagnostic);

    const history =
      ((await this.ctx.storage.get(DIAGNOSTICS_HISTORY_KEY)) as Record<string, unknown>[] | undefined) ?? [];

    history.push(diagnostic);

    if (history.length > 20) {
      history.splice(0, history.length - 20);
    }

    await this.ctx.storage.put(DIAGNOSTICS_HISTORY_KEY, history);
  }

  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/_container_status") {
      return Response.json({
        state: await this.getState(),
        containerRunning: this.runtimeContainer.running,
        diagnostics: (await this.ctx.storage.get(DIAGNOSTICS_KEY)) ?? null,
        diagnosticsHistory: (await this.ctx.storage.get(DIAGNOSTICS_HISTORY_KEY)) ?? [],
      });
    }

    try {
      return await this.containerFetch(request, this.defaultPort);
    } catch (error) {
      await this.recordDiagnostic({
        event: "container-fetch-error",
        at: new Date().toISOString(),
        message: error instanceof Error ? error.message : String(error),
      });

      return new Response(
        `Failed to serve preview container: ${error instanceof Error ? error.message : String(error)}`,
        { status: 500 }
      );
    }
  }

  override async onStart(): Promise<void> {
    await this.recordDiagnostic({
      event: "start",
      at: new Date().toISOString(),
    });
  }

  override async onStop(params: { exitCode: number; reason: string }): Promise<void> {
    await this.recordDiagnostic({
      event: "stop",
      at: new Date().toISOString(),
      exitCode: params.exitCode,
      reason: params.reason,
    });
  }

  override async onError(error: unknown): Promise<void> {
    await this.recordDiagnostic({
      event: "error",
      at: new Date().toISOString(),
      message: error instanceof Error ? error.message : String(error),
    });
  }
}

export default {
  async fetch(
    request: Request,
    env: Env,
    _ctx: ExecutionContext
  ): Promise<Response> {
    const id = env.RAILS_CONTAINER.idFromName("preview");
    const container = env.RAILS_CONTAINER.get(id);

    return container.fetch(request);
  },
};

import { Container } from "@cloudflare/containers";

interface Env {
  RAILS_CONTAINER: DurableObjectNamespace<RailsContainer>;
}

const DIAGNOSTICS_KEY = "preview-diagnostics";
const DIAGNOSTICS_HISTORY_KEY = "preview-diagnostics-history";
const START_RETRIES = 90;
const START_DELAY_MS = 1000;
const PORT_READY_TIMEOUT_MS = 300000;
const INSTANCE_GET_TIMEOUT_MS = 60000;

export class RailsContainer extends Container {
  // Rails runs on port 3000
  defaultPort = 3000;

  // Cloudflare Containers starts instances via the DO start API.
  // Set the full startup command here instead of relying on Dockerfile
  // ENTRYPOINT/CMD metadata to be carried through deployment.
  entrypoint = [
    "/rails/bin/preview-entrypoint",
    "bundle",
    "exec",
    "puma",
    "-C",
    "config/puma.rb",
  ];

  envVars = {
    RAILS_ENV: "production",
    RAILS_LOG_TO_STDOUT: "true",
    RAILS_SERVE_STATIC_FILES: "true",
    SECRET_KEY_BASE: "preview-secret-key-base-for-pr-880",
    APP_DOMAIN: "sure-preview-880.sure-finances.workers.dev",
    APP_URL: "https://sure-preview-880.sure-finances.workers.dev",
    RAILS_FORCE_SSL: "false",
    RAILS_ASSUME_SSL: "false",
    ACTIVE_STORAGE_SERVICE: "local",
    DISABLE_BOOTSNAP: "1",
    BINDING: "::",
    PREVIEW_ORIGIN: "https://sure-preview-880.sure-finances.workers.dev",
  };

  // Sleep after 30 minutes of inactivity to save resources
  sleepAfter = "30m";
  enableInternet = true;

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

  async startWithExtendedWait(signal?: AbortSignal): Promise<void> {
    await this.startAndWaitForPorts({
      startOptions: {
        entrypoint: this.entrypoint,
        envVars: this.envVars,
        enableInternet: this.enableInternet,
      },
      cancellationOptions: {
        abort: signal,
        portReadyTimeoutMS: PORT_READY_TIMEOUT_MS,
        instanceGetTimeoutMS: INSTANCE_GET_TIMEOUT_MS,
      },
    });
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

    if (url.pathname === "/_container_event" && request.method === "POST") {
      const payload = await request.json();
      await this.recordDiagnostic({
        event: "entrypoint",
        at: new Date().toISOString(),
        payload,
      });
      return new Response("ok");
    }

    try {
      await this.startWithExtendedWait(request.signal);
      return await this.containerFetch(request, this.defaultPort);
    } catch (error) {
      await this.recordDiagnostic({
        event: "extended-start-error",
        at: new Date().toISOString(),
        message: error instanceof Error ? error.message : String(error),
      });

      return new Response(
        `Failed to start preview container: ${error instanceof Error ? error.message : String(error)}`,
        { status: 500 }
      );
    }
  }

  override async onStart(): Promise<void> {
    console.log("Rails container starting...");
    await this.recordDiagnostic({
      event: "start",
      at: new Date().toISOString(),
    });
  }

  override async onStop(params: { exitCode: number; reason: string }): Promise<void> {
    console.log("Rails container stopped", params);
    await this.recordDiagnostic({
      event: "stop",
      at: new Date().toISOString(),
      exitCode: params.exitCode,
      reason: params.reason,
    });
  }

  override async onError(error: unknown): Promise<void> {
    console.error("Rails container error:", error);
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
    // Use a single container instance for this preview deployment
    // The container name is derived from the deployment, ensuring
    // each PR gets its own isolated environment
    const id = env.RAILS_CONTAINER.idFromName("preview");
    const container = env.RAILS_CONTAINER.get(id);

    // Forward the request to the Rails container
    return container.fetch(request);
  },
};

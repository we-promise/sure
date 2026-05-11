import { Container } from "@cloudflare/containers";

interface Env {
  RAILS_CONTAINER: DurableObjectNamespace<RailsContainer>;
}

const DIAGNOSTICS_KEY = "preview-diagnostics";
const START_RETRIES = 90;
const START_DELAY_MS = 1000;
const PORT_READY_TIMEOUT_MS = 120000;
const INSTANCE_GET_TIMEOUT_MS = 30000;

export class RailsContainer extends Container {
  // Rails runs on port 3000
  defaultPort = 3000;

  // Cloudflare Containers starts instances via the DO start API.
  // Set the full startup command here instead of relying on Dockerfile
  // ENTRYPOINT/CMD metadata to be carried through deployment.
  entrypoint = [
    "/rails/bin/preview-entrypoint",
    "/rails/bin/rails",
    "server",
    "-b",
    "0.0.0.0",
  ];

  envVars = {
    RAILS_ENV: "development",
    RAILS_LOG_TO_STDOUT: "true",
    RAILS_SERVE_STATIC_FILES: "true",
    PREVIEW_ORIGIN: "https://sure-preview-880.sure-finances.workers.dev",
  };

  // Sleep after 30 minutes of inactivity to save resources
  sleepAfter = "30m";
  enableInternet = true;

  get runtimeContainer() {
    return this.ctx.container!;
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
      });
    }

    if (url.pathname === "/_container_event" && request.method === "POST") {
      const payload = await request.json();
      await this.ctx.storage.put(DIAGNOSTICS_KEY, {
        event: "entrypoint",
        at: new Date().toISOString(),
        payload,
        state: await this.getState(),
      });
      return new Response("ok");
    }

    try {
      await this.startWithExtendedWait(request.signal);
      return await this.containerFetch(request, this.defaultPort);
    } catch (error) {
      await this.ctx.storage.put(DIAGNOSTICS_KEY, {
        event: "extended-start-error",
        at: new Date().toISOString(),
        message: error instanceof Error ? error.message : String(error),
        state: await this.getState(),
      });

      return new Response(
        `Failed to start preview container: ${error instanceof Error ? error.message : String(error)}`,
        { status: 500 }
      );
    }
  }

  override async onStart(): Promise<void> {
    console.log("Rails container starting...");
    await this.ctx.storage.put(DIAGNOSTICS_KEY, {
      event: "start",
      at: new Date().toISOString(),
      state: await this.getState(),
    });
  }

  override async onStop(params: { exitCode: number; reason: string }): Promise<void> {
    console.log("Rails container stopped", params);
    await this.ctx.storage.put(DIAGNOSTICS_KEY, {
      event: "stop",
      at: new Date().toISOString(),
      exitCode: params.exitCode,
      reason: params.reason,
      state: await this.getState(),
    });
  }

  override async onError(error: unknown): Promise<void> {
    console.error("Rails container error:", error);
    await this.ctx.storage.put(DIAGNOSTICS_KEY, {
      event: "error",
      at: new Date().toISOString(),
      message: error instanceof Error ? error.message : String(error),
      state: await this.getState(),
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

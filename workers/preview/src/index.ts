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

  async waitForManualStart(signal?: AbortSignal): Promise<void> {
    this.container.start({
      entrypoint: this.entrypoint,
      env: this.envVars,
    });

    for (let attempt = 1; attempt <= START_RETRIES; attempt++) {
      if (signal?.aborted) {
        throw new Error("Container request aborted.");
      }

      if (this.container.running) {
        try {
          const tcpPort = this.container.getTcpPort(this.defaultPort);
          await tcpPort.fetch("http://localhost/", { signal });
          await this.ctx.storage.put(DIAGNOSTICS_KEY, {
            event: "manual-start-ready",
            at: new Date().toISOString(),
            attempt,
            state: await this.getState(),
          });
          return;
        } catch (error) {
          await this.ctx.storage.put(DIAGNOSTICS_KEY, {
            event: "manual-start-wait",
            at: new Date().toISOString(),
            attempt,
            message: error instanceof Error ? error.message : String(error),
            state: await this.getState(),
          });
        }
      }

      await new Promise(resolve => setTimeout(resolve, START_DELAY_MS));
    }

    throw new Error("Manual start failed to make the preview container reachable.");
  }

  async proxyDirect(request: Request): Promise<Response> {
    const tcpPort = this.container.getTcpPort(this.defaultPort);
    const containerUrl = request.url.replace("https:", "http:");
    return tcpPort.fetch(containerUrl, request);
  }

  async startWithExtendedWait(signal?: AbortSignal): Promise<void> {
    await this.startAndWaitForPorts({
      startOptions: {
        entrypoint: this.entrypoint,
        envVars: this.envVars,
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
        containerRunning: this.container.running,
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

    const state = await this.getState();

    if (state.status !== "healthy") {
      try {
        await this.startWithExtendedWait(request.signal);
        return await this.proxyDirect(request);
      } catch (error) {
        await this.ctx.storage.put(DIAGNOSTICS_KEY, {
          event: "extended-start-error",
          at: new Date().toISOString(),
          message: error instanceof Error ? error.message : String(error),
          state: await this.getState(),
        });
      }
    }

    if (!this.container.running && state.status === "running") {
      await this.ctx.storage.put(DIAGNOSTICS_KEY, {
        event: "stale-state-detected",
        at: new Date().toISOString(),
        state,
      });

      try {
        await this.destroy();
      } catch (error) {
        console.warn("Container destroy during stale-state recovery failed", error);
      }

      try {
        await this.waitForManualStart(request.signal);
        return await this.proxyDirect(request);
      } catch (error) {
        await this.ctx.storage.put(DIAGNOSTICS_KEY, {
          event: "manual-recovery-error",
          at: new Date().toISOString(),
          message: error instanceof Error ? error.message : String(error),
          state: await this.getState(),
        });

        return new Response(
          `Failed to manually recover preview container: ${error instanceof Error ? error.message : String(error)}`,
          { status: 500 }
        );
      }
    }

    const response = await super.fetch(request);

    if (response.status === 500) {
      const body = await response.text();

      if (body.includes("The container is not running, consider calling start()")) {
        console.warn("Detected stale container state, forcing container restart");

        try {
          await this.destroy();
        } catch (error) {
          console.warn("Container destroy during recovery failed", error);
        }

        try {
          await this.startAndWaitForPorts({
            startOptions: {
              entrypoint: this.entrypoint,
              envVars: this.envVars,
            },
            cancellationOptions: {
              abort: request.signal,
            },
          });

          return this.containerFetch(request, this.defaultPort);
        } catch (error) {
          await this.ctx.storage.put(DIAGNOSTICS_KEY, {
            event: "recovery-error",
            at: new Date().toISOString(),
            message: error instanceof Error ? error.message : String(error),
            state: await this.getState(),
          });

          return new Response(
            `Failed to recover preview container: ${error instanceof Error ? error.message : String(error)}`,
            { status: 500 }
          );
        }
      }

      return new Response(body, {
        status: response.status,
        headers: response.headers,
      });
    }

    return response;
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

import { Container } from "@cloudflare/containers";

interface Env {
  RAILS_CONTAINER: DurableObjectNamespace<RailsContainer>;
}

interface DiagnosticPayload {
  stage?: string;
  detail?: string;
}

interface DiagnosticRecord {
  event?: string;
  at?: string;
  payload?: DiagnosticPayload;
  state?: { status?: string; lastChange?: number };
  message?: string;
}

interface PreviewProgress {
  phase: "cold" | "warming" | "loading-demo-data" | "ready" | "failed";
  stage: string | null;
  message: string;
  detail: string;
}

interface PreviewStatusPayload {
  state: unknown;
  containerRunning: boolean;
  diagnostics: DiagnosticRecord | null;
  diagnosticsHistory: DiagnosticRecord[];
  previewReady: boolean;
  previewFailed: boolean;
  progress: PreviewProgress;
}

const DIAGNOSTICS_KEY = "preview-diagnostics";
const DIAGNOSTICS_HISTORY_KEY = "preview-diagnostics-history";
const READY_STAGES = new Set(["demo-data-ready", "demo-data-skip"]);
const FAILED_STAGES = new Set(["demo-data-failed", "failed"]);
const WAITING_MESSAGES: Record<string, string> = {
  boot: "Waking preview…",
  "redis-start": "Starting Redis…",
  "redis-ready": "Redis is ready.",
  "postgres-start": "Starting PostgreSQL…",
  "postgres-ready": "PostgreSQL is ready.",
  "postgres-already-running": "PostgreSQL is already running.",
  "db-setup": "Setting up the preview database…",
  "db-prepare": "Running database setup…",
  "db-prepare-done": "Database setup finished.",
  "demo-data-check": "Checking sample data…",
  "demo-data-user-present": "Found the demo user. Verifying sample data…",
  "demo-data-deferred": "Rails is up. Loading sample data…",
  "demo-data-load": "Loading sample data…",
  "demo-data-ready": "Sample data is ready.",
  "demo-data-skip": "Sample data is already ready.",
  "demo-data-failed": "Sample data failed to load.",
  "rails-start": "Starting Rails…",
  "rails-up-ready": "Rails is up. Finishing sample data…",
  "rails-up-timeout": "Rails is taking longer than expected to start.",
};

export class RailsContainer extends Container {
  defaultPort = 3000;
  pingEndpoint = "container/up";
  entrypoint = ["/rails/bin/preview-entrypoint", "bundle", "exec", "puma", "-C", "config/puma.rb"];
  envVars = {
    RAILS_ENV: "production",
    RAILS_LOG_TO_STDOUT: "true",
    RAILS_SERVE_STATIC_FILES: "true",
    SECRET_KEY_BASE: "preview-secret-key-base-for-pr-${PR_NUMBER}",
    APP_DOMAIN: "sure-preview-${PR_NUMBER}.sure-finances.workers.dev",
    APP_URL: "https://sure-preview-${PR_NUMBER}.sure-finances.workers.dev",
    RAILS_FORCE_SSL: "false",
    RAILS_ASSUME_SSL: "false",
    ACTIVE_STORAGE_SERVICE: "local",
    DISABLE_BOOTSNAP: "1",
    BINDING: "::",
    DEMO_DATA_SEED: "${PR_NUMBER}",
    PREVIEW_ORIGIN: "https://sure-preview-${PR_NUMBER}.sure-finances.workers.dev",
  };
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

  private async getDiagnostics(): Promise<{
    state: unknown;
    containerRunning: boolean;
    diagnostics: DiagnosticRecord | null;
    diagnosticsHistory: DiagnosticRecord[];
  }> {
    return {
      state: await this.getState(),
      containerRunning: this.runtimeContainer.running,
      diagnostics: ((await this.ctx.storage.get(DIAGNOSTICS_KEY)) as DiagnosticRecord | undefined) ?? null,
      diagnosticsHistory:
        ((await this.ctx.storage.get(DIAGNOSTICS_HISTORY_KEY)) as DiagnosticRecord[] | undefined) ?? [],
    };
  }

  private async probeRailsUp(): Promise<boolean> {
    try {
      const response = await this.containerFetch(new Request("https://container.internal/up"), this.defaultPort);
      return response.ok;
    } catch {
      return false;
    }
  }

  private async buildPreviewStatus(base: {
    state: unknown;
    containerRunning: boolean;
    diagnostics: DiagnosticRecord | null;
    diagnosticsHistory: DiagnosticRecord[];
  }, options?: { probe?: boolean }): Promise<PreviewStatusPayload> {
    const allDiagnostics = [...base.diagnosticsHistory, ...(base.diagnostics ? [base.diagnostics] : [])];
    const entrypointDiagnostics = allDiagnostics.filter(
      (item) => item.event === "entrypoint" && typeof item.payload?.stage === "string"
    );
    const latestEntrypoint = entrypointDiagnostics.at(-1) ?? null;
    const latestStage = latestEntrypoint?.payload?.stage ?? null;
    const latestDetail = latestEntrypoint?.payload?.detail ?? base.diagnostics?.message ?? "";
    const sampleDataReady = entrypointDiagnostics.some((item) => READY_STAGES.has(item.payload?.stage ?? ""));
    const liveProbeReady = options?.probe ? await this.probeRailsUp() : false;
    const railsResponding =
      liveProbeReady ||
      (typeof base.state === "object" && base.state !== null && "status" in base.state
        ? (base.state as { status?: string }).status === "healthy"
        : false) ||
      entrypointDiagnostics.some((item) => item.payload?.stage === "rails-up-ready");
    const previewReady = liveProbeReady || (sampleDataReady && railsResponding);
    const previewFailed =
      entrypointDiagnostics.some((item) => FAILED_STAGES.has(item.payload?.stage ?? "")) ||
      base.diagnostics?.event === "error";

    let phase: PreviewProgress["phase"] = "cold";
    if (previewFailed) {
      phase = "failed";
    } else if (previewReady) {
      phase = "ready";
    } else if (
      latestStage === "demo-data-load" ||
      latestStage === "demo-data-deferred" ||
      latestStage === "rails-up-ready" ||
      latestStage === "demo-data-check" ||
      latestStage === "demo-data-user-present"
    ) {
      phase = "loading-demo-data";
    } else if (base.containerRunning || latestEntrypoint) {
      phase = "warming";
    }

    const message = sampleDataReady && !previewReady
      ? "Finishing preview startup…"
      : (latestStage ? WAITING_MESSAGES[latestStage] : undefined) ??
        (previewFailed
          ? "Preview startup hit an error."
          : previewReady
            ? "Preview is ready."
            : base.containerRunning
              ? "Warming preview…"
              : "Starting preview…");

    return {
      ...base,
      previewReady,
      previewFailed,
      progress: {
        phase,
        stage: latestStage,
        message,
        detail: latestDetail,
      },
    };
  }

  private wantsHtml(request: Request): boolean {
    if (request.method !== "GET") return false;
    const accept = request.headers.get("accept") ?? "";
    const secFetchDest = request.headers.get("sec-fetch-dest") ?? "";
    return accept.includes("text/html") || secFetchDest === "document";
  }

  private renderWaitPage(request: Request, status: PreviewStatusPayload, errorMessage?: string): Response {
    const targetPath = new URL(request.url).pathname + new URL(request.url).search;
    const escapedTargetPath = JSON.stringify(targetPath);
    const escapedMessage = JSON.stringify(status.progress.message);
    const escapedDetail = JSON.stringify(
      status.progress.detail || errorMessage || "This preview is waking up and loading sample data."
    );

    const html = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Waking preview…</title>
    <style>
      :root { color-scheme: light dark; }
      body { margin: 0; font-family: Inter, ui-sans-serif, system-ui, sans-serif; background: #0b1220; color: #e5eefc; }
      .wrap { min-height: 100vh; display: grid; place-items: center; padding: 24px; }
      .card { width: min(100%, 520px); background: rgba(15, 23, 42, 0.92); border: 1px solid rgba(148, 163, 184, 0.2); border-radius: 20px; padding: 28px; box-shadow: 0 20px 50px rgba(0,0,0,0.35); }
      .spinner { width: 42px; height: 42px; border-radius: 999px; border: 4px solid rgba(148,163,184,0.28); border-top-color: #60a5fa; animation: spin 0.9s linear infinite; margin-bottom: 18px; }
      h1 { margin: 0 0 10px; font-size: 1.5rem; }
      p { margin: 0; line-height: 1.55; color: #cbd5e1; }
      .detail { margin-top: 12px; font-size: 0.95rem; color: #93c5fd; }
      .hint { margin-top: 18px; font-size: 0.9rem; color: #94a3b8; }
      .error { margin-top: 18px; color: #fca5a5; }
      @keyframes spin { to { transform: rotate(360deg); } }
    </style>
  </head>
  <body>
    <div class="wrap">
      <div class="card">
        <div class="spinner" aria-hidden="true"></div>
        <h1 id="message"></h1>
        <p id="detail"></p>
        <p class="hint">Please wait — this preview is cold-starting and will redirect automatically when the sample data is ready.</p>
        <p class="error" id="error"></p>
      </div>
    </div>
    <script>
      const targetPath = ${escapedTargetPath};
      const messageEl = document.getElementById("message");
      const detailEl = document.getElementById("detail");
      const errorEl = document.getElementById("error");
      const update = (status) => {
        messageEl.textContent = status?.progress?.message || ${escapedMessage};
        detailEl.textContent = status?.progress?.detail || ${escapedDetail};
        if (status?.previewFailed) {
          errorEl.textContent = "Preview startup hit an error. Still retrying — refresh if this persists.";
        }
      };
      update(null);
      const poll = async () => {
        try {
          const response = await fetch("/_container_status", { cache: "no-store" });
          if (!response.ok) throw new Error("status " + response.status);
          const status = await response.json();
          update(status);
          if (status.previewReady) {
            window.location.replace(targetPath);
            return;
          }
        } catch (error) {
          const reason = error instanceof Error ? error.message : String(error);
          errorEl.textContent = "Still waking the preview (" + reason + ").";
        }
        window.setTimeout(poll, 1500);
      };
      window.setTimeout(poll, 1500);
    </script>
  </body>
</html>`;

    return new Response(html, {
      status: status.previewFailed ? 503 : 202,
      headers: {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store, max-age=0",
        "retry-after": "3",
      },
    });
  }

  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/_container_status") {
      return Response.json(await this.buildPreviewStatus(await this.getDiagnostics(), { probe: true }));
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
      return await this.containerFetch(request, this.defaultPort);
    } catch (error) {
      await this.recordDiagnostic({
        event: "container-fetch-error",
        at: new Date().toISOString(),
        message: error instanceof Error ? error.message : String(error),
      });

      const status = await this.buildPreviewStatus(await this.getDiagnostics());
      if (this.wantsHtml(request) && !status.previewReady) {
        return this.renderWaitPage(
          request,
          status,
          error instanceof Error ? error.message : String(error)
        );
      }

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

  override async onStop(stopParams: { exitCode?: number; reason?: string }): Promise<void> {
    await this.recordDiagnostic({
      event: "stop",
      at: new Date().toISOString(),
      exitCode: stopParams.exitCode,
      reason: stopParams.reason,
    });
  }

  override async onError(error: unknown): Promise<void> {
    console.error("Rails container error:", error);
    await this.recordDiagnostic({
      event: "error",
      at: new Date().toISOString(),
      message: error instanceof Error ? error.message : String(error),
    });
    throw error;
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

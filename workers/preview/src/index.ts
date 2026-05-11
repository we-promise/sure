import { Container } from "@cloudflare/containers";

interface Env {
  RAILS_CONTAINER: DurableObjectNamespace<RailsContainer>;
}

export class RailsContainer extends Container {
  // Rails runs on port 3000
  defaultPort = 3000;

  // Cloudflare Containers starts instances via the DO start API.
  // Set the full startup command here instead of relying on Dockerfile
  // ENTRYPOINT/CMD metadata to be carried through deployment.
  entrypoint = [
    "/rails/bin/preview-entrypoint",
    "./bin/rails",
    "server",
    "-b",
    "0.0.0.0",
  ];

  envVars = {
    RAILS_ENV: "development",
    RAILS_LOG_TO_STDOUT: "true",
    RAILS_SERVE_STATIC_FILES: "true",
  };

  // Sleep after 30 minutes of inactivity to save resources
  sleepAfter = "30m";

  override onStart(): void {
    console.log("Rails container starting...");
  }

  override onStop(): void {
    console.log("Rails container stopped");
  }

  override onError(error: unknown): void {
    console.error("Rails container error:", error);
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

import { Container } from "@cloudflare/containers";

interface Env {
  RAILS_CONTAINER: DurableObjectNamespace<RailsContainer>;
}

export class RailsContainer extends Container {
  // Rails runs on port 3000
  defaultPort = 3000;

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

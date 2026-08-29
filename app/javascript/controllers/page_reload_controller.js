import { Controller } from "@hotwired/stimulus";

// Full page reload (not a Turbo morph refresh) for the rare cases where the
// page needs a genuinely fresh load — e.g. after fixing an infra
// misconfiguration (Redis) that may also be breaking the Turbo/Action Cable
// connection itself, where a client-side morph can't be trusted to work.
export default class extends Controller {
  reload() {
    window.location.reload();
  }
}

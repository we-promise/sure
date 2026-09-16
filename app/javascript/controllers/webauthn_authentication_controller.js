import WebauthnController from "controllers/webauthn_controller";
import {
  prepareCredentialRequestOptions,
  serializePublicKeyCredential,
} from "utils/webauthn";

export default class extends WebauthnController {
  static targets = ["error"];
  static values = {
    optionsUrl: String,
    verifyUrl: String,
    unsupportedMessage: String,
    errorFallback: String,
    // Opt in to browser autofill ("conditional mediation"): passkeys are
    // offered from the username field instead of behind a button click. Only
    // passwordless sign-in enables this; the MFA step-up does not.
    conditional: Boolean,
  };

  connect() {
    if (this.conditionalValue) this.#startConditionalMediation();
  }

  disconnect() {
    this.abortConditionalMediation();
  }

  async authenticate(event) {
    event.preventDefault();
    this.clearError();

    if (!window.PublicKeyCredential) {
      this.showError(this.unsupportedMessageValue);
      return;
    }

    // A second click would mint a fresh challenge while the first
    // authenticator prompt is still open, so the assertion the user is about
    // to produce would verify against a challenge the server has replaced.
    if (this.authenticating) return;
    this.authenticating = true;

    // A pending conditional request holds the challenge minted on connect.
    // Fetching options below replaces it server-side, so the stale request has
    // to go first or its assertion would verify against a challenge that no
    // longer exists.
    this.abortConditionalMediation();

    try {
      const options = await this.fetchOptions();
      const credential = await navigator.credentials.get({
        publicKey: prepareCredentialRequestOptions(options),
      });

      await this.verifyCredential(serializePublicKeyCredential(credential));
    } catch (error) {
      this.showError(error.message);
    } finally {
      this.authenticating = false;
    }
  }

  async #startConditionalMediation() {
    // Created before the first await so a button click or a Turbo disconnect
    // in the meantime has something to abort. Held in a local because
    // abortConditionalMediation() nulls the field.
    const controller = new AbortController();
    this.abortController = controller;

    const available =
      await window.PublicKeyCredential?.isConditionalMediationAvailable?.();
    if (!available || controller.signal.aborted) return;

    let credential;

    try {
      const options = await this.fetchOptions(controller.signal);
      if (controller.signal.aborted) return;

      credential = await navigator.credentials.get({
        publicKey: prepareCredentialRequestOptions(options),
        mediation: "conditional",
        signal: controller.signal,
      });
    } catch (_error) {
      // Nothing has been asked of the user yet: aborted, dismissed, or the
      // background options request failed. Surfacing that would paint an error
      // on a login page nobody has touched.
      return;
    }

    if (controller.signal.aborted || !credential) return;

    try {
      await this.verifyCredential(serializePublicKeyCredential(credential));
    } catch (error) {
      // The user did pick a passkey from the autofill menu, so a rejection
      // here has to be visible.
      this.showError(error.message);
    }
  }

  abortConditionalMediation() {
    this.abortController?.abort();
    this.abortController = null;
  }

  // Takes a signal so the conditional flow's request can be cancelled. The
  // challenge rides in the session cookie, so a response whose Set-Cookie never
  // lands cannot overwrite the challenge a manual click just minted.
  async fetchOptions(signal) {
    const response = await fetch(this.optionsUrlValue, {
      method: "POST",
      headers: this.headers,
      credentials: "same-origin",
      signal,
    });

    if (!response.ok) throw new Error(await this.errorMessage(response));

    return response.json();
  }

  async verifyCredential(credential) {
    const response = await fetch(this.verifyUrlValue, {
      method: "POST",
      headers: this.headers,
      credentials: "same-origin",
      body: JSON.stringify({ credential }),
    });

    if (!response.ok) throw new Error(await this.errorMessage(response));

    const result = await response.json();
    window.location.href = result.redirect_url;
  }
}

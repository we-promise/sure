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
    if (this.conditionalValue) this.startConditionalMediation();
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
    }
  }

  async startConditionalMediation() {
    const available =
      await window.PublicKeyCredential?.isConditionalMediationAvailable?.();
    if (!available) return;

    this.abortController = new AbortController();

    try {
      const options = await this.fetchOptions();
      const credential = await navigator.credentials.get({
        publicKey: prepareCredentialRequestOptions(options),
        mediation: "conditional",
        signal: this.abortController.signal,
      });

      await this.verifyCredential(serializePublicKeyCredential(credential));
    } catch (_error) {
      // Aborted, dismissed, or the user signed in another way. This runs
      // without a user gesture, so failures stay silent.
    }
  }

  abortConditionalMediation() {
    this.abortController?.abort();
    this.abortController = null;
  }

  async fetchOptions() {
    const response = await fetch(this.optionsUrlValue, {
      method: "POST",
      headers: this.headers,
      credentials: "same-origin",
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

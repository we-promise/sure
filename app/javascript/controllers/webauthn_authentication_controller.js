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
  };

  async authenticate(event) {
    event.preventDefault();
    this.clearError();

    if (!window.PublicKeyCredential) {
      this.showError(this.unsupportedMessageValue);
      return;
    }

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

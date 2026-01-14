import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["error"];
  static values = {
    optionsUrl: String,
    authenticateUrl: String
  };

  async authenticate(event) {
    event.preventDefault();
    this.clearError();

    // Check if WebAuthn is available (requires HTTPS or localhost)
    if (!window.PublicKeyCredential) {
      this.showError("Passkeys are not supported in this browser. Please use a modern browser with HTTPS.");
      return;
    }

    if (!window.isSecureContext) {
      this.showError("Passkeys require a secure connection (HTTPS). Please access this site via HTTPS.");
      return;
    }

    try {
      // Get authentication options from server (no email required for discoverable credentials)
      const optionsResponse = await fetch(this.optionsUrlValue, {
        method: "GET",
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": this.csrfToken
        }
      });

      if (!optionsResponse.ok) {
        const errorData = await optionsResponse.json();
        throw new Error(errorData.error || "Failed to get authentication options");
      }

      const options = await optionsResponse.json();

      // Convert base64url to ArrayBuffer for WebAuthn API
      options.challenge = this.base64urlToBuffer(options.challenge);
      if (options.allowCredentials) {
        options.allowCredentials = options.allowCredentials.map(cred => ({
          ...cred,
          id: this.base64urlToBuffer(cred.id)
        }));
      }

      // Get credential via browser WebAuthn API
      // For discoverable credentials, the browser will show all available passkeys
      const credential = await navigator.credentials.get({ publicKey: options });

      // Send credential to server
      const authResponse = await fetch(this.authenticateUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": this.csrfToken
        },
        body: JSON.stringify({
          credential: this.serializeCredential(credential)
        })
      });

      const result = await authResponse.json();

      if (result.success) {
        window.location.href = result.redirect_to;
      } else {
        this.showError(result.error || "Authentication failed");
      }
    } catch (error) {
      console.error("Passkey authentication failed:", error);
      if (error.name === "NotAllowedError") {
        this.showError("Passkey authentication was cancelled or no passkeys found");
      } else {
        this.showError(error.message || "Authentication failed");
      }
    }
  }

  serializeCredential(credential) {
    return {
      id: credential.id,
      type: credential.type,
      rawId: this.bufferToBase64url(credential.rawId),
      response: {
        clientDataJSON: this.bufferToBase64url(credential.response.clientDataJSON),
        authenticatorData: this.bufferToBase64url(credential.response.authenticatorData),
        signature: this.bufferToBase64url(credential.response.signature),
        userHandle: credential.response.userHandle ? this.bufferToBase64url(credential.response.userHandle) : null
      }
    };
  }

  base64urlToBuffer(base64url) {
    const padding = "=".repeat((4 - (base64url.length % 4)) % 4);
    const base64 = base64url.replace(/-/g, "+").replace(/_/g, "/") + padding;
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes.buffer;
  }

  bufferToBase64url(buffer) {
    const bytes = new Uint8Array(buffer);
    let binary = "";
    for (let i = 0; i < bytes.length; i++) {
      binary += String.fromCharCode(bytes[i]);
    }
    return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
  }

  showError(message) {
    if (this.hasErrorTarget) {
      this.errorTarget.textContent = message;
      this.errorTarget.classList.remove("hidden");
    }
  }

  clearError() {
    if (this.hasErrorTarget) {
      this.errorTarget.textContent = "";
      this.errorTarget.classList.add("hidden");
    }
  }

  get csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content;
  }
}

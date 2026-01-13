import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["label", "error", "list"];
  static values = {
    createOptionsUrl: String,
    createUrl: String
  };

  async register(event) {
    event.preventDefault();
    this.clearError();

    try {
      // Get registration options from server
      const optionsResponse = await fetch(this.createOptionsUrlValue, {
        method: "GET",
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": this.csrfToken
        }
      });

      if (!optionsResponse.ok) {
        throw new Error("Failed to get registration options");
      }

      const options = await optionsResponse.json();

      // Convert base64url to ArrayBuffer for WebAuthn API
      options.challenge = this.base64urlToBuffer(options.challenge);
      options.user.id = this.base64urlToBuffer(options.user.id);
      if (options.excludeCredentials) {
        options.excludeCredentials = options.excludeCredentials.map(cred => ({
          ...cred,
          id: this.base64urlToBuffer(cred.id)
        }));
      }

      // Create credential via browser WebAuthn API
      const credential = await navigator.credentials.create({ publicKey: options });

      // Send credential to server
      const createResponse = await fetch(this.createUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": this.csrfToken
        },
        body: JSON.stringify({
          credential: this.serializeCredential(credential),
          label: this.hasLabelTarget ? this.labelTarget.value : null
        })
      });

      const result = await createResponse.json();

      if (result.success) {
        // Reload page to show updated passkey list
        window.location.reload();
      } else {
        this.showError(result.error || "Failed to register passkey");
      }
    } catch (error) {
      console.error("Passkey registration failed:", error);
      if (error.name === "NotAllowedError") {
        this.showError("Passkey registration was cancelled");
      } else {
        this.showError(error.message || "Failed to register passkey");
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
        attestationObject: this.bufferToBase64url(credential.response.attestationObject)
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

import { Controller } from "@hotwired/stimulus";

const messageHandlers = [
  (payload) => window.webkit?.messageHandlers?.hotwireNative?.postMessage?.(payload),
  (payload) => window.HotwireNative?.postMessage?.(payload),
  (payload) => window.HotwireNativeBridge?.postMessage?.(payload),
];

export default class extends Controller {
  static values = {
    navigation: Array,
    activePath: String,
  };

  connect() {
    this.visitListener = this.handleVisitRequest.bind(this);
    this.boundHandleTurboLoad = this.handleTurboLoad.bind(this);

    document.addEventListener("hotwire-native:visit", this.visitListener);
    document.addEventListener("turbo:load", this.boundHandleTurboLoad);

    window.hotwireNative ||= {};
    window.hotwireNative.visit = (url, options = {}) => {
      if (!url) return;
      window.Turbo?.visit(url, options);
    };

    this.publish({ event: "connect" });
  }

  disconnect() {
    document.removeEventListener("hotwire-native:visit", this.visitListener);
    document.removeEventListener("turbo:load", this.boundHandleTurboLoad);
  }

  navigationValueChanged() {
    this.publish({ event: "navigation:update" });
  }

  activePathValueChanged() {
    this.publish({ event: "location:update" });
  }

  handleTurboLoad() {
    this.publish({ event: "visit" });
  }

  handleVisitRequest(event) {
    const { url, options } = event.detail || {};
    if (!url) {
      return;
    }

    window.Turbo?.visit(url, options || {});
  }

  publish({ event }) {
    const payload = {
      event,
      url: window.location.href,
      path: this.activePathValue || window.location.pathname,
      title: document.title,
      navigation: this.navigationValue || [],
    };

    document.dispatchEvent(
      new CustomEvent("hotwire-native:bridge", { detail: payload }),
    );

    messageHandlers.some((handler) => {
      if (typeof handler !== "function") {
        return false;
      }

      try {
        handler(payload);
        return true;
      } catch (error) {
        console.warn("Failed to notify native bridge", error);
        return false;
      }
    });
  }
}

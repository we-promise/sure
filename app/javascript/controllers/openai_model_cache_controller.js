import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["uriBase", "modelInput", "modelSelect", "hint"];
  static values = { fetchedModels: Array };

  connect() {
    const uriBase = this.currentUriBase();
    const fetchedModels = this.normalizedModels(this.fetchedModelsValue);

    if (fetchedModels.length > 0) {
      this.writeCachedModels(uriBase, fetchedModels);
      this.showModelSelect(fetchedModels);
      return;
    }

    this.showModelSelect(this.readCachedModels(uriBase));
  }

  uriBaseChanged() {
    this.showModelSelect(this.readCachedModels(this.currentUriBase()));
  }

  currentUriBase() {
    return this.hasUriBaseTarget ? this.uriBaseTarget.value.trim() : "";
  }

  normalizedModels(models) {
    return Array.from(new Set(Array(models).filter((model) => typeof model === "string" && model.trim().length > 0)));
  }

  storageKey(uriBase) {
    return `openai-models:${uriBase || "default"}`;
  }

  writeCachedModels(uriBase, models) {
    try {
      localStorage.setItem(this.storageKey(uriBase), JSON.stringify(models));
    } catch (_error) {
      // Ignore storage failures in private mode or blocked storage contexts.
    }
  }

  readCachedModels(uriBase) {
    try {
      const raw = localStorage.getItem(this.storageKey(uriBase));
      return this.normalizedModels(raw ? JSON.parse(raw) : []);
    } catch (_error) {
      return [];
    }
  }

  showModelSelect(models) {
    if (!this.hasModelInputTarget || !this.hasModelSelectTarget || !this.hasHintTarget) return;

    if (models.length === 0) {
      this.modelInputTarget.disabled = false;
      this.modelInputTarget.classList.remove("hidden");
      this.modelSelectTarget.disabled = true;
      this.modelSelectTarget.classList.add("hidden");
      this.hintTarget.classList.add("hidden");
      return;
    }

    const selectedModel = this.modelInputTarget.value;
    const selectedValue = models.includes(selectedModel) ? selectedModel : "";

    const options = ['<option value=""></option>']
      .concat(models.map((model) => `<option value="${this.escapeHtml(model)}">${this.escapeHtml(model)}</option>`));
    this.modelSelectTarget.innerHTML = options.join("");
    this.modelSelectTarget.value = selectedValue;

    this.modelSelectTarget.disabled = false;
    this.modelSelectTarget.classList.remove("hidden");
    this.modelInputTarget.disabled = true;
    this.modelInputTarget.classList.add("hidden");
    this.hintTarget.classList.remove("hidden");
  }

  escapeHtml(value) {
    return value
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#39;");
  }
}

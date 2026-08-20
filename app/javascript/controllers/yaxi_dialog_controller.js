import { Controller } from "@hotwired/stimulus";
import { Confirmation, Field, SecrecyLevel, Selection } from "routex-client";

export default class extends Controller {
  static targets = ["message", "image", "options", "fieldGroup", "field", "continue"];
  static values = { fallbackMessage: String };

  disconnect() {
    if (this.imageUrl) URL.revokeObjectURL(this.imageUrl);
  }

  show(event) {
    this.response = event.detail.response;
    this.element.classList.remove("hidden");
    this.messageTarget.textContent = this.response.message || this.fallbackMessageValue;
    this.optionsTarget.replaceChildren();
    this.fieldGroupTarget.classList.add("hidden");
    this.continueTarget.classList.remove("hidden");
    this.renderImage();

    if (this.response.input instanceof Selection) this.renderSelection();
    else if (this.response.input instanceof Field) this.renderField();
    else if (this.response.input instanceof Confirmation && this.response.input.pollingDelaySecs) {
      this.continueTarget.classList.add("hidden");
      window.setTimeout(() => this.confirm(), this.response.input.pollingDelaySecs * 1000);
    }
  }

  continue() {
    if (this.response.input instanceof Field) return this.respond(this.fieldTarget.value);
    return this.confirm();
  }

  select(event) {
    this.respond(event.params.value);
  }

  hide() {
    this.element.classList.add("hidden");
  }

  renderSelection() {
    this.continueTarget.classList.add("hidden");
    const template = this.element.querySelector("template");
    for (const option of this.response.input.options) {
      const button = template.content.firstElementChild.cloneNode(true);
      button.textContent = option.explanation ? `${option.label} — ${option.explanation}` : option.label;
      button.dataset.action = "yaxi-dialog#select";
      button.dataset.yaxiDialogValueParam = option.key;
      this.optionsTarget.append(button);
    }
  }

  renderField() {
    this.fieldGroupTarget.classList.remove("hidden");
    this.fieldTarget.value = "";
    this.fieldTarget.type = this.response.input.secrecyLevel === SecrecyLevel.Password ? "password" : "text";
    if (this.response.input.minLength) this.fieldTarget.minLength = this.response.input.minLength;
    if (this.response.input.maxLength) this.fieldTarget.maxLength = this.response.input.maxLength;
    this.fieldTarget.focus();
  }

  renderImage() {
    if (!this.response.image) return this.imageTarget.classList.add("hidden");
    if (this.imageUrl) URL.revokeObjectURL(this.imageUrl);
    this.imageUrl = URL.createObjectURL(new Blob([this.response.image.data], { type: this.response.image.mimeType }));
    this.imageTarget.src = this.imageUrl;
    this.imageTarget.classList.remove("hidden");
  }

  respond(value) {
    this.hide();
    this.dispatch("respond", { detail: { value }, prefix: "yaxi-dialog" });
  }

  confirm() {
    this.hide();
    this.dispatch("confirm", { prefix: "yaxi-dialog" });
  }
}

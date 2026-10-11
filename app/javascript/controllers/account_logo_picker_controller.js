import { Controller } from "@hotwired/stimulus";

// A whole domain, as Account.normalize_institution_domain leaves it.
const DOMAIN = /^([a-z0-9-]+\.)+(xn--[a-z0-9-]+|[a-z]{2,})$/;

function normalizeDomain(value) {
  return (value || "")
    .trim()
    .toLowerCase()
    .replace(/^[a-z][a-z0-9+.-]*:\/\//, "")
    .split(/[/?#]/)[0]
    .replace(/:\d+$/, "")
    .replace(/^www\./, "");
}

// Previews the icon chosen in the account form. Nothing is saved until the
// form is submitted: a picked or removed icon travels in a hidden field, an
// upload in the file field.
export default class extends Controller {
  static targets = [
    "preview",
    "image",
    "caption",
    "choice",
    "file",
    "option",
    "fallback",
    "blank",
    "pick",
    "pickHint",
  ];
  static values = { pending: String, removal: String, providerDomain: String };

  // Stimulus connects targets before connect(), so the field is looked up
  // on demand and the button state is set again once listening.
  connect() {
    this.listenedField = this.domainField;
    this.listenedField?.addEventListener("input", this.updatePick);
    this.updatePick();
  }

  get domainField() {
    return this.element
      .closest("form")
      ?.elements.namedItem("account[institution_domain]");
  }

  disconnect() {
    this.listenedField?.removeEventListener("input", this.updatePick);
  }

  pickTargetConnected() {
    this.updatePick();
  }

  // "Pick icon" stays clickable when there is no domain yet, so a hover or a
  // tap can say why it does nothing; a disabled button would show neither.
  updatePick = () => {
    if (!this.hasPickTarget) return;

    const ready = this.domainReady();
    this.pickTarget.setAttribute("aria-disabled", String(!ready));
    this.pickTarget.classList.toggle("opacity-50", !ready);
    this.pickTarget.classList.toggle("cursor-not-allowed", !ready);
    this.pickTarget.title = ready ? "" : this.pickHintTarget.textContent.trim();
    if (ready) this.pickHintTarget.classList.add("hidden");
  };

  // A linked account may take its domain from the provider while the field is blank.
  domainReady() {
    const typed = normalizeDomain(this.domainField?.value);
    return DOMAIN.test(typed || this.providerDomainValue);
  }

  // The picker reloads the icon block from the server, which shows the saved
  // icon, so an earlier choice starts over; a selected file is kept.
  previewTargetConnected() {
    this.savedImage = [...this.imageTarget.childNodes].map((node) =>
      node.cloneNode(true),
    );
    this.savedCaption = this.captionTarget.textContent;
    this.choiceTarget.value = "";
    this.showFile();
  }

  // The picker searches what the account form holds now, not what was saved.
  search(event) {
    if (!this.domainReady()) {
      event.preventDefault();
      this.pickHintTarget.classList.remove("hidden");
      return;
    }

    const { currentTarget } = event;
    const typed = this.element.closest("form").elements;
    const query = currentTarget.form.elements;

    for (const name of ["institution_domain", "institution_name"]) {
      const field = typed.namedItem(`account[${name}]`);
      const input = query.namedItem(name);
      if (field && input) input.value = field.value;
    }
  }

  choose({ params: { choice, label }, currentTarget }) {
    this.clearFile();

    if (choice) {
      this.choiceTarget.value = choice;
      this.showImage(
        currentTarget.querySelector("img").src,
        `${label} · ${this.pendingValue}`,
      );
    } else {
      this.restore();
    }

    this.highlight(currentTarget);
  }

  // Removing brings back the automatic icon, so that is what the preview shows.
  remove() {
    this.clearFile();
    this.restore();
    this.choiceTarget.value = "remove";
    this.imageTarget.replaceChildren(
      this.fallbackTarget.content.cloneNode(true),
    );
    this.captionTarget.textContent = this.removalValue;
    this.highlight(null);
  }

  showFile() {
    const file = this.hasFileTarget && this.fileTarget.files[0];
    if (!file) return;

    this.choiceTarget.value = "";
    this.showImage(
      URL.createObjectURL(file),
      `${file.name} · ${this.pendingValue}`,
    );
    this.highlight(null);
  }

  // The image comes from the server-rendered blank, so it keeps the shape of
  // every other account logo.
  showImage(src, caption) {
    const image = this.blankTarget.content.querySelector("img").cloneNode();
    image.src = src;
    this.imageTarget.replaceChildren(image);
    this.captionTarget.textContent = caption;
  }

  restore() {
    this.choiceTarget.value = "";
    this.imageTarget.replaceChildren(
      ...this.savedImage.map((node) => node.cloneNode(true)),
    );
    this.captionTarget.textContent = this.savedCaption;
  }

  clearFile() {
    if (this.hasFileTarget) this.fileTarget.value = "";
  }

  highlight(selected) {
    for (const option of this.optionTargets) {
      const active = option === selected;
      option.classList.toggle("border-primary", active);
      option.classList.toggle("border-secondary", !active);
    }
  }
}

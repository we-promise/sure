import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["format", "panel", "csvOptions", "kind", "transactionFormat", "csvSource", "fileInput"];

  connect() {
    this.update();
  }

  update(event) {
    const format = this.formatTarget.value;

    if (event?.target.matches('[data-import-flow-target~="kind"]')) {
      this.kindTargets.forEach((kind) => {
        kind.value = event.target.value;
      });
    }
    if (event?.target.matches('[data-import-flow-target~="csvSource"]')) {
      this.csvSourceTargets.forEach((source) => {
        source.value = event.target.value;
      });
    }

    this.panelTargets.forEach((panel) => {
      panel.hidden = panel.dataset.importFlowPanel !== format;
    });
    this.csvOptionsTarget.hidden = format !== "csv";

    const importKind = this.kindTargets.find((kind) => kind.tagName === "SELECT")?.value;
    this.transactionFormatTarget.hidden = importKind !== "TransactionImport";

    const csvSource = this.csvSourceTargets.find((source) => source.tagName === "SELECT")?.value;
    if (importKind) {
      this.kindTargets.forEach((kind) => {
        kind.value = importKind;
      });
    }
    if (csvSource) {
      this.csvSourceTargets.forEach((source) => {
        source.value = csvSource;
      });
    }

    this.fileInputTargets.forEach((input) => {
      input.disabled = input.dataset.importFlowFileFormat !== format;
      input.required = !input.disabled;
    });

    const url = new URL(window.location.href);
    url.searchParams.set("file_format", format);
    if (importKind) url.searchParams.set("import_kind", importKind);
    if (csvSource) url.searchParams.set("csv_format", csvSource);
    window.history.replaceState({}, "", url);
  }

  uploadSure(event) {
    const input = this.fileInputTargets.find((target) => target.dataset.importFlowFileFormat === "sure");

    if (input && input.files.length === 0) {
      event.preventDefault();
      input.click();
    }
  }
}

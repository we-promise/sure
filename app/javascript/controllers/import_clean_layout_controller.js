import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["table", "pdf", "hidePdfControl", "showPdfControl"];

  static values = {
    pdfVisible: Boolean,
  };

  connect() {
    if (!this.hasPdfTarget) return;

    this.setPdfVisibility(this.pdfVisibleValue, { updateUrl: false });
  }

  togglePdf() {
    this.setPdfVisibility(!this.pdfVisibleValue);
  }

  setPdfVisibility(visible, { updateUrl = true } = {}) {
    if (!this.hasPdfTarget) return;

    this.pdfVisibleValue = visible;
    this.pdfTarget.classList.toggle("hidden", !visible);
    this.tableTarget.classList.toggle("lg:col-span-3", visible);
    this.tableTarget.classList.toggle("lg:col-span-4", !visible);
    this.hidePdfControlTarget.classList.toggle("hidden", !visible);
    this.showPdfControlTarget.classList.toggle("hidden", visible);

    if (updateUrl) {
      const url = new URL(window.location.href);
      if (visible) {
        url.searchParams.set("show_pdf", "1");
        url.searchParams.delete("hide_pdf");
      } else {
        url.searchParams.delete("show_pdf");
        url.searchParams.delete("hide_pdf");
      }
      window.history.replaceState({}, "", url);
    }
  }
}

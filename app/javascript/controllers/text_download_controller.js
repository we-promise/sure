import { Controller } from "@hotwired/stimulus";

// Builds a client-side text file download from embedded report text. Keeps the
// user-submitted content out of any href (so it can't become a data:/javascript:
// URI) and avoids data-URI length limits on large batches.
export default class extends Controller {
  static targets = ["source"];
  static values = { filename: String };

  download() {
    const text = this.sourceTarget?.textContent ?? "";
    const blob = new Blob([text], { type: "text/plain" });
    const url = URL.createObjectURL(blob);

    const link = document.createElement("a");
    link.href = url;
    link.download = this.filenameValue || "download.txt";
    document.body.appendChild(link);
    link.click();
    link.remove();

    URL.revokeObjectURL(url);
  }
}

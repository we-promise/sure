import { Controller } from "@hotwired/stimulus";

// Elements whose text names a setting or states it: headings, field labels and
// primary-colored lines. Muted description text is not searchable.
const TEXT_SELECTOR = "h2, h3, h4, legend, label, summary, p.text-primary";
// Text inside these is not shown, or is not part of a setting.
const SKIPPED_SELECTOR =
  "nav, header, footer, script, style, template, dialog, [hidden], [aria-hidden='true'], .hidden, .sr-only";
const MAX_SETTING_RESULTS = 8;
const FRAGMENT_WORDS = 8;
const INDEX_TTL_MS = 5 * 60 * 1000;

// Shared across Turbo visits so the pages are read once, not on every page.
let settingsIndex = null;

// Connects to data-controller="settings-search"
// Searches the settings pages and, once the pages have been read, the text of
// the settings on them. Nothing is listed by hand: whatever a page shows is
// searchable, so a new setting turns up as soon as it exists.
//
// The server renders every settings page into the results list; this
// controller decides which are visible and in what order, swaps the results
// for the regular navigation while a query is present, adds matching settings
// as extra rows, and moves the keyboard highlight between matches.
export default class extends Controller {
  static targets = ["input", "nav", "results", "item", "empty", "template"];
  static values = { pages: Array };

  connect() {
    this.settingRows = [];
    this.filter();
  }

  // Reads the searchable pages the first time the field is used.
  async load() {
    if (this.loading || this.isFresh()) return;

    this.loading = true;
    settingsIndex = { loadedAt: Date.now(), entries: await this.readPages() };
    this.loading = false;
    this.filter();
  }

  filter() {
    const query = this.normalize(this.inputTarget.value);
    const searching = query.length > 0;

    this.navTarget.classList.toggle("hidden", searching);
    this.resultsTarget.classList.toggle("hidden", !searching);
    this.inputTarget.setAttribute("aria-expanded", String(searching));

    this.clearSettingRows();

    const pages = this.rankPages(query);
    const settings = this.rankSettings(query).map((setting) =>
      this.buildRow(setting),
    );
    const rows = [...pages, ...settings]
      .map((row, position) => ({ row, position }))
      .sort((a, b) => a.row.score - b.row.score || a.position - b.position)
      .map(({ row }) => row.element);

    const shown = new Set(rows);
    this.itemTargets.forEach((item) => {
      item.classList.toggle("hidden", !shown.has(item));
      item.style.order = "";
    });
    rows.forEach((element, order) => {
      element.style.order = order;
    });

    this.emptyTarget.classList.toggle(
      "hidden",
      !searching || rows.length > 0 || this.loading,
    );
    this.highlight(rows[0]);
  }

  keydown(event) {
    switch (event.key) {
      case "ArrowDown":
        event.preventDefault();
        this.moveHighlight(1);
        break;
      case "ArrowUp":
        event.preventDefault();
        this.moveHighlight(-1);
        break;
      case "Enter":
        this.openHighlighted(event);
        break;
      case "Escape":
        this.escape(event);
        break;
    }
  }

  // Pages whose name, section or text matches. A name that starts with the
  // query beats one that merely contains it, which beats a match elsewhere.
  rankPages(query) {
    if (!query) return [];

    return this.itemTargets.flatMap((element) => {
      const score = this.score(
        query,
        this.normalize(element.dataset.searchLabel),
        this.normalize(element.dataset.searchText),
      );
      return score === null ? [] : [{ element, score }];
    });
  }

  // Settings found on the pages, best match first.
  rankSettings(query) {
    if (!query || !settingsIndex) return [];

    return settingsIndex.entries
      .flatMap((entry) => {
        const score = this.score(query, entry.text, entry.text);
        return score === null ? [] : [{ ...entry, score }];
      })
      .sort((a, b) => a.score - b.score)
      .slice(0, MAX_SETTING_RESULTS);
  }

  score(query, label, text) {
    const terms = query.split(" ");
    if (!terms.every((term) => text.includes(term))) return null;
    if (label.startsWith(query)) return 0;
    if (label.includes(query)) return 1;
    if (terms.every((term) => label.includes(term))) return 2;
    return 3;
  }

  // The row for one setting: its own text, cut off with an ellipsis, over the
  // page it lives on.
  buildRow(setting) {
    const element =
      this.templateTarget.content.firstElementChild.cloneNode(true);
    const link = element.querySelector("a");
    const page = this.itemTargets.find(
      (item) => item.dataset.pagePath === setting.path,
    );

    link.href = `${setting.path}${this.textFragment(setting.display)}`;
    link.id = `settings-search-setting-${this.settingRows.length}`;
    element.querySelector("[data-slot=title]").textContent = setting.display;
    element.querySelector("[data-slot=subtitle]").textContent = setting.label;
    const icon = page?.querySelector("svg");
    if (icon) {
      element.querySelector("[data-slot=icon]").append(icon.cloneNode(true));
    }

    this.resultsTarget.querySelector("ul").append(element);
    this.settingRows.push(element);
    return { element, score: setting.score };
  }

  clearSettingRows() {
    this.settingRows.forEach((row) => row.remove());
    this.settingRows = [];
  }

  // Browsers scroll to and highlight the text a fragment names.
  textFragment(text) {
    const start = text.split(" ").slice(0, FRAGMENT_WORDS).join(" ");
    return `#:~:text=${encodeURIComponent(start).replace(/-/g, "%2D")}`;
  }

  moveHighlight(direction) {
    const visible = this.visibleRows;
    if (visible.length === 0) return;

    const current = visible.indexOf(this.highlighted);
    const next = (current + direction + visible.length) % visible.length;
    this.highlight(visible[next]);
  }

  highlight(target) {
    this.highlighted = target;

    this.visibleRows.forEach((row) => {
      row
        .querySelector("a")
        .setAttribute("aria-selected", String(row === target));
    });

    if (target) {
      const link = target.querySelector("a");
      this.inputTarget.setAttribute("aria-activedescendant", link.id);
      link.scrollIntoView({ block: "nearest" });
    } else {
      this.inputTarget.removeAttribute("aria-activedescendant");
    }
  }

  openHighlighted(event) {
    if (!this.highlighted) return;

    event.preventDefault();
    this.highlighted.querySelector("a").click();
  }

  // Escape clears a query first; with nothing left to clear it leaves the field.
  escape(event) {
    event.preventDefault();

    if (this.inputTarget.value) {
      this.inputTarget.value = "";
      this.filter();
    } else {
      this.inputTarget.blur();
    }
  }

  get visibleRows() {
    return [...this.itemTargets, ...this.settingRows]
      .filter((row) => !row.classList.contains("hidden"))
      .sort((a, b) => Number(a.style.order) - Number(b.style.order));
  }

  isFresh() {
    return settingsIndex && Date.now() - settingsIndex.loadedAt < INDEX_TTL_MS;
  }

  async readPages() {
    const pages = await Promise.all(
      this.pagesValue.map((page) => this.readPage(page)),
    );
    return pages.flat();
  }

  // Every distinct piece of text a page shows as a setting. A page that cannot
  // be read is left out rather than breaking the search.
  async readPage({ path, label }) {
    try {
      const response = await fetch(path, {
        headers: { Accept: "text/html" },
        credentials: "same-origin",
      });
      if (!response.ok) return [];

      const document = new DOMParser().parseFromString(
        await response.text(),
        "text/html",
      );
      const seen = new Set();

      return [
        ...(document.querySelector("main")?.querySelectorAll(TEXT_SELECTOR) ??
          []),
      ]
        .filter((element) => !element.closest(SKIPPED_SELECTOR))
        .filter((element) => !element.querySelector(TEXT_SELECTOR))
        .map((element) => element.textContent.replace(/\s+/g, " ").trim())
        .filter(
          (display) =>
            display.length > 2 && !seen.has(display) && seen.add(display),
        )
        .map((display) => ({
          path,
          label,
          display,
          text: this.normalize(display),
        }));
    } catch {
      return [];
    }
  }

  // Lowercase, strip diacritics and treat punctuation as a space, so
  // "two factor" finds "Two-Factor" and "securite" finds "Sécurité".
  normalize(value) {
    return (value ?? "")
      .normalize("NFD")
      .replace(/\p{M}/gu, "")
      .toLocaleLowerCase()
      .replace(/[^\p{L}\p{N}]+/gu, " ")
      .trim();
  }
}

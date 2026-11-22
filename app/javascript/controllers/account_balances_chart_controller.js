import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import {
  DAY,
  buildLanePoints,
  buildRows,
  clusterByDistance,
  columnSplit,
  currencyAffixes,
  excludedFromSettings,
  extendSignRuns,
  formatDay,
  groupingFor,
  interpolate,
  laneBills,
  monthFormatFor,
  parseDay,
  pluralForm,
  selectionToSave,
  stackRows,
  zoomTarget,
} from "utils/account_balances_chart";
import {
  CHART_TOOLTIP_CLASSES,
  CHART_TOOLTIP_CONTEXT_CLASSES,
  CHART_TOOLTIP_VALUE_CLASSES,
} from "utils/chart_tooltip";

const CASH_TYPES = new Set(["Depository", "CreditCard", "Unassigned"]);
const MIN_ZOOM = DAY / 4; // deep enough to spread one day's transactions apart
const LANE_GAP = 20; // px: lane dots closer than this merge into a group
const ITEM_PX = 22; // px per transaction before a day's transactions spread out
const TIP_ITEMS = 8; // transactions listed in a lane tooltip
const SAVE_DELAY = 400;

// Account Balances dashboard widget: stacked balance per account with a
// forecast, an account list, an optional transaction lane and drag-to-zoom.
// Renders into every chart / list / stats target, so the full-screen dialog
// shows the same chart as the widget.
export default class extends Controller {
  static targets = [
    "saveError",
    "controls",
    "secondaryInk",
    "subduedInk",
    "chart",
    "list",
    "stats",
    "icons",
    "horizonSegment",
    "hideNegativeToggle",
    "hideNegativeNote",
    "showTransactionsToggle",
    "showTransactionsNote",
  ];

  static values = {
    data: Object,
    settings: Object,
    labels: Object,
    transactionsUrl: String,
    transactionsIndexUrl: String,
    locale: String,
    preferencesUrl: String,
  };

  connect() {
    // Stimulus parses an Object value's JSON on every read; parse once.
    this.chartData = this.dataValue;
    this.labels = this.labelsValue;
    const settings = this.settingsValue;
    this.horizon = settings.horizon;
    this.hideNegative = settings.hide_negative;
    this.showTransactions = settings.show_transactions;
    this.excluded = excludedFromSettings(
      settings,
      this.chartData.accounts.map((a) => a.id),
    );
    this.listOpen = settings.list_open;
    this.openGroups = new Set(settings.open_groups);
    this.zoom = null;

    // Numbers and dates follow the family's currency and date settings.
    const money = this.chartData.money_format;
    const [prefix, suffix] = currencyAffixes(money.format, money.unit);
    const numberLocale = {
      decimal: money.separator,
      thousands: money.delimiter,
      grouping: groupingFor(money),
      minus: "-",
    };
    const currency = d3.formatLocale({
      ...numberLocale,
      currency: [prefix, suffix],
    });
    const number = d3.formatLocale({ ...numberLocale, currency: ["", ""] });
    this.fmt = currency.format("$,.0f");
    this.fmtSigned = currency.format("+$,.0f");
    this.fmtNum = number.format(",.0f");
    this.fmtNumSigned = number.format("+,.0f");
    this.fmtAxis = (v) =>
      Math.abs(v) >= 1000
        ? `${number.format(",.0f")(v / 1000)}k`
        : number.format(",.0f")(v);
    const dateFormat = this.chartData.date_format || "%Y-%m-%d";
    this.dayLabel = d3.utcFormat(dateFormat);
    this.monthLabel = d3.utcFormat(monthFormatFor(dateFormat));
    this.timeLabel = d3.utcFormat(`${dateFormat} %H:%M`);
    this.isoLabel = (isoDate) => this.dayLabel(parseDay(isoDate));

    this.colors = this.#assignColors();
    this.draw();
    if (this.showTransactions) this.#loadTransactions();

    this.resizeObserver = new ResizeObserver(() => this.draw());
    for (const el of this.chartTargets) this.resizeObserver.observe(el);
  }

  disconnect() {
    this.resizeObserver?.disconnect();
    this.#flushSave({ keepalive: true });
  }

  // The dashboard section grabs Enter/Space/arrows for drag-reordering; keys
  // pressed inside the widget (checkboxes, buttons) stay here.
  stopKeydown(event) {
    event.stopPropagation();
  }

  // --- settings ---
  setHorizon(event) {
    this.horizon = Number(event.currentTarget.dataset.months);
    this.#changed();
  }

  toggleHideNegative(event) {
    this.hideNegative = event.target.checked;
    this.#changed();
  }

  toggleShowTransactions(event) {
    this.showTransactions = event.target.checked;
    this.#save();
    if (this.showTransactions && !this.transactions) this.#loadTransactions();
    else this.draw();
  }

  #changed() {
    this.#save();
    this.draw();
  }

  // Saved through the dashboard preferences endpoint, debounced. A save
  // still pending when the widget goes away (navigation) is flushed then.
  #save() {
    clearTimeout(this.saveTimer);
    this.savePending = true;
    this.saveTimer = setTimeout(() => this.#flushSave(), SAVE_DELAY);
  }

  async #flushSave({ keepalive = false } = {}) {
    clearTimeout(this.saveTimer);
    if (!this.savePending) return;
    this.savePending = false;
    // Saves are not serialized: only the latest one sent may change the
    // saved/unsaved state, so an older request finishing last is ignored.
    this.saveRevision = (this.saveRevision || 0) + 1;
    const revision = this.saveRevision;
    const token = document.querySelector('meta[name="csrf-token"]')?.content;
    try {
      const response = await fetch(this.preferencesUrlValue, {
        method: "PATCH",
        keepalive,
        headers: { "Content-Type": "application/json", "X-CSRF-Token": token },
        body: JSON.stringify({
          preferences: {
            account_balances: {
              horizon: this.horizon,
              hide_negative: this.hideNegative,
              show_transactions: this.showTransactions,
              ...selectionToSave(
                this.excluded,
                this.chartData.accounts.map((a) => a.id),
              ),
              list_open: this.listOpen,
              open_groups: [...this.openGroups],
            },
          },
        }),
      });
      if (!response.ok) {
        console.error(
          "[Account Balances] Failed to save settings:",
          response.status,
        );
      }
      if (revision === this.saveRevision) this.#saveFailed(!response.ok);
    } catch (error) {
      console.error("[Account Balances] Network error saving settings:", error);
      if (revision === this.saveRevision) this.#saveFailed(true);
    }
  }

  // A failed save stays pending, so the next change (or leaving the
  // dashboard) sends the current settings again; until a save succeeds the
  // widget says the settings are not saved.
  #saveFailed(failed) {
    if (failed) this.savePending = true;
    for (const note of this.saveErrorTargets) note.hidden = !failed;
  }

  #syncSettings() {
    for (const segment of this.horizonSegmentTargets) {
      const active = Number(segment.dataset.months) === this.horizon;
      segment.classList.toggle("segmented-control__segment--active", active);
      segment.setAttribute("aria-pressed", String(active));
    }
    for (const toggle of this.hideNegativeToggleTargets) {
      toggle.disabled = !this.canHideNegative;
      toggle.checked = this.hideNegative && this.canHideNegative;
    }
    for (const note of this.hideNegativeNoteTargets) {
      note.textContent = this.canHideNegative
        ? this.t("hide_negative_hint")
        : this.t("hide_negative_unavailable", { date: this.firstNegativeDay });
    }
    for (const toggle of this.showTransactionsToggleTargets)
      toggle.checked = this.showTransactions;
    for (const note of this.showTransactionsNoteTargets) {
      note.textContent =
        this.transactionsState === "loading"
          ? this.t("transactions_loading")
          : this.transactionsState === "error"
            ? this.t("transactions_error")
            : this.t("show_transactions_hint");
    }
  }

  // --- account selection ---
  #toggleAccounts(ids) {
    const allShown = ids.every((id) => !this.excluded.has(id));
    for (const id of ids) {
      if (allShown) this.excluded.add(id);
      else this.excluded.delete(id);
    }
    this.#changed();
  }

  #preset(name) {
    const accounts = this.chartData.accounts;
    if (name === "all") this.excluded = new Set();
    if (name === "none") this.excluded = new Set(accounts.map((a) => a.id));
    if (name === "cash")
      this.excluded = new Set(
        accounts.filter((a) => !CASH_TYPES.has(a.type)).map((a) => a.id),
      );
    this.#changed();
  }

  // The background a chart sits on: the dialog in full screen, else the card.
  #surface(el) {
    return getComputedStyle(
      el.closest("dialog") || this.element.closest("section") || document.body,
    ).backgroundColor;
  }

  // --- data ---
  // Plural forms come as a Rails plural hash; Intl.PluralRules picks the
  // form for the user's locale (one/few/many/other), falling back to other.
  tp(key, count, vars = {}) {
    const forms = this.labels[key];
    if (typeof forms !== "object" || forms === null)
      return this.t(key, { count, ...vars });
    return interpolate(pluralForm(forms, count, this.localeValue || "en"), {
      count,
      ...vars,
    });
  }

  t(key, vars) {
    return interpolate(this.labels[key] ?? key, vars);
  }

  // A design-system control rendered by the view into the controls template.
  #control(name) {
    return this.controlsTarget.content
      .querySelector(`[data-control="${name}"]`)
      .cloneNode(true);
  }

  #icon(name) {
    return (
      this.iconsTarget.content.querySelector(`[data-icon="${name}"]`)
        ?.innerHTML ?? ""
    );
  }

  // One colour family per account type (Sure's colour for the type); inside
  // a family the accounts fan out over neighbouring hues and alternate dark /
  // light in stack order, so adjacent layers differ in hue and lightness.
  // Fixed per account, not per rank, so hiding one never repaints the others.
  #assignColors() {
    const colors = {};
    for (const members of d3
      .group(this.chartData.accounts, (a) => a.type)
      .values()) {
      const base = d3.hcl(members[0].color);
      const n = members.length;
      const spread = n <= 1 ? 0 : Math.min(70, 16 * (n - 1));
      members.forEach((account, k) => {
        const color = base.copy();
        if (n > 1) {
          color.h = base.h + (-spread / 2 + (spread * k) / (n - 1));
          color.l = Math.max(
            30,
            Math.min(84, base.l + (k % 2 ? 15 : -10) + (k % 4 >= 2 ? 5 : 0)),
          );
        }
        colors[account.id] = color.formatHex();
      });
    }
    return colors;
  }

  #model() {
    const { rows, today } = buildRows(this.chartData, this.horizon);
    const keys = this.chartData.accounts
      .map((a) => a.id)
      .filter((id) => !this.excluded.has(id));
    const net = (row) => keys.reduce((sum, key) => sum + row.values[key], 0);
    const todayRow =
      rows.find((row) => +row.date === +today) || rows[rows.length - 1];
    const last = rows[rows.length - 1];
    const future = rows.filter((row) => row.forecast);
    const goesNegative = new Map(
      this.chartData.accounts
        .filter(
          (a) =>
            !a.liability &&
            a.type !== "Unassigned" &&
            todayRow.values[a.id] >= 0,
        )
        .map((a) => [a.id, future.find((row) => row.values[a.id] < 0)])
        .filter(([, row]) => row),
    );
    const firstNegative = keys.length
      ? rows.find((row) => net(row) < -0.5)
      : null;
    return {
      rows,
      today,
      keys,
      net,
      todayRow,
      last,
      future,
      goesNegative,
      firstNegative,
    };
  }

  // --- render ---
  draw() {
    const model = this.#model();
    // "Hide below zero" only while the total stays at or above zero over the
    // whole range, so the top of the stack (the total) never leaves the chart.
    this.canHideNegative = model.keys.length > 0 && !model.firstNegative;
    this.firstNegativeDay = model.firstNegative
      ? this.dayLabel(model.firstNegative.date)
      : null;
    model.hideNegative = this.hideNegative && this.canHideNegative;
    this.#syncSettings();
    for (const el of this.statsTargets) this.#renderStats(el, model);
    for (const el of this.listTargets) this.#renderList(el, model);
    for (const el of this.chartTargets) this.#drawChart(el, model);
  }

  #renderStats(el, { keys, net, todayRow, last, future, goesNegative }) {
    if (!keys.length) {
      el.replaceChildren();
      return;
    }
    const stat = (label, value, sub) =>
      `<div><p class="text-xs text-secondary">${label}</p><p class="text-xl font-medium text-primary tabular-nums">${value}</p>${
        sub ? `<p class="text-xs text-secondary tabular-nums">${sub}</p>` : ""
      }</div>`;
    let html = stat(this.t("stat_today"), this.fmt(net(todayRow)));
    if (this.horizon && last.forecast) {
      const low = d3.least(future, net);
      html += stat(
        this.t("stat_forecast", { date: this.dayLabel(last.date) }),
        this.fmt(net(last)),
        this.t("stat_vs_today", {
          amount: this.fmtSigned(net(last) - net(todayRow)),
        }),
      );
      html += stat(
        this.t("stat_lowest"),
        this.fmt(net(low)),
        this.dayLabel(low.date),
      );
      const names = Object.fromEntries(
        this.chartData.accounts.map((a) => [a.id, a.name]),
      );
      const negative = [...goesNegative].filter(([id]) => keys.includes(id));
      if (negative.length) {
        const accounts = negative
          .map(
            ([id, row]) =>
              `${escapeHtml(names[id])} (${this.dayLabel(row.date)})`,
          )
          .join(", ");
        html += `<p class="text-xs text-secondary self-end max-w-xs">${this.#icon("warning")} ${this.t("goes_negative", { accounts })}</p>`;
      }
    }
    el.innerHTML = html;
  }

  // Groups in the order the chart shows them, top to bottom: asset layers
  // stack upward in account order, so they are listed reversed; liabilities
  // and bills without an account hang below zero and come last.
  #groups() {
    const byType = new Map();
    for (const account of this.chartData.accounts) {
      if (!byType.has(account.type)) {
        byType.set(account.type, {
          type: account.type,
          label:
            account.type === "Unassigned" ? account.name : account.type_label,
          below: account.liability || account.type === "Unassigned",
          accounts: [],
        });
      }
      byType.get(account.type).accounts.push(account);
    }
    const groups = [...byType.values()];
    const above = groups
      .filter((g) => !g.below)
      .reverse()
      .map((g) => ({ ...g, accounts: [...g.accounts].reverse() }));
    return [...above, ...groups.filter((g) => g.below)];
  }

  #renderList(el, { todayRow, last, goesNegative }) {
    const withForecast = this.horizon > 0 && last.forecast;
    const focused = el.contains(document.activeElement)
      ? document.activeElement.dataset.focusKey
      : null;
    const accounts = this.chartData.accounts;
    const shown = accounts.filter((a) => !this.excluded.has(a.id)).length;
    const rowClass = withForecast
      ? "grid grid-cols-[minmax(0,1fr)_5.75rem_5.75rem_5.25rem] @max-md:grid-cols-[minmax(0,1fr)_5.5rem_5.5rem] gap-x-3 items-center px-1.5 py-0.5 min-h-7 rounded-md"
      : "grid grid-cols-[minmax(0,1fr)_6rem] gap-x-3 items-center px-1.5 py-0.5 min-h-7 rounded-md";
    const value = (account, row) => row.values[account.id] ?? 0;
    const numbers = (today, end) =>
      `<span class="text-right tabular-nums whitespace-nowrap">${this.fmtNum(today)}</span>${
        withForecast
          ? `<span class="text-right tabular-nums whitespace-nowrap">${this.fmtNum(end)}</span><span class="text-right tabular-nums whitespace-nowrap text-secondary @max-md:hidden">${
              Math.abs(end - today) < 0.5 ? "–" : this.fmtNumSigned(end - today)
            }</span>`
          : ""
      }`;
    const empty = `<span class="text-right">–</span>${withForecast ? '<span class="text-right">–</span><span class="text-right @max-md:hidden">–</span>' : ""}`;
    const warn = (row) =>
      `<span class="shrink-0 text-secondary" title="${escapeHtml(this.t("goes_negative_on", { date: this.dayLabel(row.date) }))}">${this.#icon("warning")}</span>`;
    const caret = (open, key, label) =>
      `<button type="button" class="shrink-0 w-5 h-5 inline-flex items-center justify-center rounded text-secondary hover:text-primary" data-caret="${escapeHtml(key)}" data-focus-key="caret-${escapeHtml(key)}" aria-expanded="${open}" aria-label="${escapeHtml(label)}"><span class="inline-flex transition-transform ${open ? "rotate-90" : ""}">${this.#icon("chevron")}</span></button>`;

    const header = `
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1 mb-1">
        <button type="button" class="inline-flex items-center gap-1 text-xs text-secondary hover:text-primary" data-list-toggle data-focus-key="list-toggle" aria-expanded="${this.listOpen}">
          <span class="inline-flex transition-transform ${this.listOpen ? "rotate-90" : ""}">${this.#icon("chevron")}</span>
          <span class="font-medium">${escapeHtml(this.t("list_title"))}</span>
          <span>· ${escapeHtml(shown === accounts.length ? this.t("list_shown_all", { count: accounts.length }) : this.t("list_shown_some", { shown, count: accounts.length }))}</span>
        </button>
        ${this.listOpen ? "<span data-presets-slot></span>" : ""}
      </div>`;

    if (!this.listOpen) {
      el.innerHTML = header;
      this.#bindList(el, [], focused);
      return;
    }

    const blocks = this.#groups().map((group) => {
      const ids = group.accounts.map((a) => a.id);
      const on = group.accounts.filter((a) => !this.excluded.has(a.id));
      const open = this.openGroups.has(group.type);
      const hidden = group.accounts.length - on.length;
      const sum = (row) => d3.sum(on, (a) => value(a, row));
      const groupWarning = on
        .map((a) => goesNegative.get(a.id))
        .filter(Boolean)
        .sort((x, y) => x.date - y.date)[0];
      const meta =
        group.accounts.length === 1
          ? ""
          : hidden
            ? this.t("list_hidden", { hidden, count: group.accounts.length })
            : String(group.accounts.length);
      let html = `<div class="${rowClass} font-medium mt-0.5 hover:bg-container-inset ${on.length ? "" : "text-secondary"}" data-group="${escapeHtml(group.type)}">
        <span class="flex items-center gap-2 min-w-0">
          ${caret(open, group.type, this.t(open ? "list_collapse" : "list_expand", { name: group.label }))}
          <label class="flex items-center gap-2 min-w-0 cursor-pointer">
            <input type="checkbox" class="checkbox checkbox--light shrink-0" data-group-check data-focus-key="group-${escapeHtml(group.type)}" ${on.length === group.accounts.length ? "checked" : ""}>
            <span class="truncate">${escapeHtml(group.label)}</span>
          </label>
          ${meta ? `<span class="text-xs font-normal text-secondary truncate">${escapeHtml(meta)}</span>` : ""}
          ${groupWarning ? warn(groupWarning) : ""}
        </span>
        ${on.length ? numbers(sum(todayRow), sum(last)) : empty}
      </div>`;
      if (open) {
        html += group.accounts
          .map((account) => {
            const isOn = !this.excluded.has(account.id);
            const warning = goesNegative.get(account.id);
            return `<div class="${rowClass} pl-8 hover:bg-container-inset ${isOn ? "" : "text-secondary"}" data-account="${escapeHtml(account.id)}">
              <span class="flex items-center gap-2 min-w-0">
                <label class="flex items-center gap-2 min-w-0 cursor-pointer">
                  <input type="checkbox" class="checkbox checkbox--light shrink-0" data-account-check data-focus-key="account-${escapeHtml(account.id)}" ${isOn ? "checked" : ""}>
                  <span class="w-2.5 h-2.5 rounded-sm shrink-0 ${isOn ? "" : "opacity-40"}" style="background:${this.colors[account.id]}"></span>
                  <span class="truncate" title="${escapeHtml(account.name)}">${escapeHtml(account.name)}</span>
                </label>
                ${warning ? warn(warning) : ""}
              </span>
              ${numbers(value(account, todayRow), value(account, last))}
            </div>`;
          })
          .join("");
      }
      // Column weight counts every account as if open, so opening or closing
      // a group never moves a group to the other column.
      return {
        html,
        weight: 1 + group.accounts.length,
        group,
        ids,
        partial: on.length > 0 && on.length < group.accounts.length,
      };
    });

    const cut = columnSplit(blocks.map((b) => b.weight));
    const columnHeader = (second) =>
      `<div class="${rowClass} min-h-6 text-xs text-secondary border-b border-secondary rounded-none ${second ? "hidden @4xl:grid" : ""}">
        <span>${escapeHtml(this.t("list_account"))}</span><span class="text-right">${escapeHtml(this.t("list_today"))}</span>${
          withForecast
            ? `<span class="text-right">${this.dayLabel(last.date)}</span><span class="text-right @max-md:hidden">${escapeHtml(this.t("list_change"))}</span>`
            : ""
        }
      </div>`;
    const column = (part, second) =>
      `<div class="min-w-0">${columnHeader(second)}${part.map((b) => b.html).join("")}</div>`;
    el.innerHTML = `${header}<div class="grid grid-cols-1 @4xl:grid-cols-2 gap-x-8 items-start">${column(blocks.slice(0, cut), false)}${
      cut < blocks.length ? column(blocks.slice(cut), true) : ""
    }</div>`;
    this.#bindList(el, blocks, focused);
  }

  #bindList(el, blocks, focused) {
    el.querySelector("[data-list-toggle]").addEventListener("click", () => {
      this.listOpen = !this.listOpen;
      this.#changed();
    });
    el.querySelector("[data-presets-slot]")?.replaceWith(
      this.#control("presets"),
    );
    for (const preset of el.querySelectorAll("[data-preset]")) {
      preset.addEventListener("click", () =>
        this.#preset(preset.dataset.preset),
      );
    }
    for (const block of blocks) {
      const row = el.querySelector(
        `[data-group="${CSS.escape(block.group.type)}"]`,
      );
      const check = row.querySelector("[data-group-check]");
      check.indeterminate = block.partial;
      check.addEventListener("change", () => this.#toggleAccounts(block.ids));
      row.querySelector("[data-caret]").addEventListener("click", () => {
        if (this.openGroups.has(block.group.type))
          this.openGroups.delete(block.group.type);
        else this.openGroups.add(block.group.type);
        this.#changed();
      });
      row.addEventListener("pointerenter", () => this.#highlight(block.ids));
      row.addEventListener("pointerleave", () => this.#highlight(null));
    }
    for (const row of el.querySelectorAll("[data-account]")) {
      row
        .querySelector("[data-account-check]")
        .addEventListener("change", () =>
          this.#toggleAccounts([row.dataset.account]),
        );
      row.addEventListener("pointerenter", () =>
        this.#highlight([row.dataset.account]),
      );
      row.addEventListener("pointerleave", () => this.#highlight(null));
    }
    if (focused)
      el.querySelector(`[data-focus-key="${CSS.escape(focused)}"]`)?.focus();
  }

  // Brings some accounts' layers forward and dims the rest, in every chart.
  #highlight(ids) {
    const set = ids ? new Set(ids) : null;
    for (const el of this.chartTargets) {
      d3.select(el)
        .selectAll("path[data-key]")
        .style("opacity", function () {
          return !set || set.has(this.dataset.key) ? null : 0.22;
        });
    }
  }

  // --- zoom (drag-select on the chart) ---
  #setZoom(start, end) {
    let a = +start;
    let b = +end;
    if (b - a < MIN_ZOOM) {
      const mid = (a + b) / 2;
      a = mid - MIN_ZOOM / 2;
      b = mid + MIN_ZOOM / 2;
    }
    this.zoom = [new Date(a), new Date(b)];
    this.transactionsFailed = false; // a new zoom may try loading older transactions again
    this.draw();
  }

  #resetZoom() {
    if (!this.zoom) return;
    this.zoom = null;
    this.transactionsFailed = false;
    this.draw();
  }

  #drawChart(el, model) {
    const width = el.clientWidth;
    const height = el.clientHeight;
    if (!width || !height) return; // e.g. the full-screen copy while its dialog is closed
    const { rows: allRows, today, keys, net, hideNegative } = model;

    el.replaceChildren();
    if (!keys.length || allRows.length < 2) {
      const message = document.createElement("div");
      message.className =
        "w-full h-full flex items-center justify-center text-sm text-secondary";
      message.textContent = keys.length
        ? this.t("no_history")
        : this.t("no_accounts_selected");
      el.append(message);
      return;
    }

    // Each row's value holds until the next row (step curve), so the
    // domain runs to one day past the last row.
    const full = [
      allRows[0].date,
      new Date(+allRows[allRows.length - 1].date + DAY),
    ];
    const domain = this.zoom
      ? [
          new Date(Math.max(+full[0], +this.zoom[0])),
          new Date(Math.min(+full[1], +this.zoom[1])),
        ]
      : full;
    if (domain[1] - domain[0] < DAY / 8) {
      this.zoom = null;
      this.#drawChart(el, model);
      return;
    }
    // Visible rows, plus the one before (still showing at the left edge).
    const bisect = d3.bisector((row) => row.date);
    const first = Math.max(0, bisect.right(allRows, domain[0]) - 1);
    const lastIndex = Math.min(
      allRows.length - 1,
      bisect.left(allRows, domain[1]),
    );
    const rows = allRows.slice(first, lastIndex + 1);

    const AXIS_H = 22;
    const LANE_H = this.showTransactions ? 30 : 0;
    const margin = { top: 8, right: 12, bottom: AXIS_H + LANE_H, left: 48 };
    const series = stackRows(rows, keys);
    // A copy of the last point one day on, so the final step is as wide as the others.
    const tailRow = {
      ...rows[rows.length - 1],
      date: new Date(+rows[rows.length - 1].date + DAY),
    };
    for (const s of series) {
      const lastPoint = s[s.length - 1];
      s.push(
        Object.assign([...lastPoint], {
          data: tailRow,
          negative: lastPoint.negative,
        }),
      );
    }
    const lineRows = [...rows, tailRow];

    const x = d3
      .scaleUtc()
      .domain(domain)
      .range([margin.left, width - margin.right]);
    const low = hideNegative
      ? 0
      : Math.min(
          0,
          d3.min(series, (s) => d3.min(s, (p) => p[0])),
        );
    const high = Math.max(
      0,
      d3.max(series, (s) => d3.max(s, (p) => p[1])),
    );
    const y = d3
      .scaleLinear()
      .domain([low, high])
      .nice()
      .range([height - margin.bottom, margin.top]);
    const surface = this.#surface(el);
    const ink = getComputedStyle(this.element).color;
    const plotWidth = width - margin.left - margin.right;

    const svg = d3
      .select(el)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("role", "img")
      .attr("aria-label", this.t("chart_aria_label"))
      .attr("class", "text-secondary");
    const uid = Math.random().toString(36).slice(2);
    const todayX = Math.max(
      margin.left,
      Math.min(width - margin.right, x(today)),
    );
    const defs = svg.append("defs");
    const clip = (id, x0, w, h) =>
      defs
        .append("clipPath")
        .attr("id", `${id}-${uid}`)
        .append("rect")
        .attr("x", x0)
        .attr("y", 0)
        .attr("width", w)
        .attr("height", h);
    clip("abc-x", margin.left, plotWidth, height);
    clip("abc-past", 0, todayX, height);
    clip("abc-plot", 0, width, y(0));
    clip("abc-future", todayX, Math.max(0, width - todayX), height);

    svg
      .append("g")
      .attr("transform", `translate(0,${height - AXIS_H})`)
      .call(this.#xAxis(x, width).tickSizeOuter(0))
      .call((g) => g.selectAll("path, line").attr("stroke-opacity", 0.25))
      .call((g) => g.selectAll("text").style("fill", "currentColor"));
    svg
      .append("g")
      .attr("transform", `translate(${margin.left},0)`)
      .call(
        d3
          .axisLeft(y)
          .ticks(Math.max(2, Math.floor(height / 50)))
          .tickFormat(this.fmtAxis)
          .tickSize(-plotWidth),
      )
      .call((g) => g.select(".domain").remove())
      .call((g) => g.selectAll(".tick line").attr("stroke-opacity", 0.12))
      .call((g) => g.selectAll("text").style("fill", "currentColor"));

    // Positive stretches first, then negative ones on top (they overlap the
    // bottom of the positive stack) with a hatch so the overlap reads as owed.
    const area = (negative) =>
      d3
        .area()
        .defined((p) => p.negative === negative)
        .x((p) => x(p.data.date))
        .y0((p) => y(p[0]))
        .y1((p) => y(p[1]))
        .curve(d3.curveStepAfter);
    defs
      .append("pattern")
      .attr("id", `abc-hatch-${uid}`)
      .attr("width", 6)
      .attr("height", 6)
      .attr("patternUnits", "userSpaceOnUse")
      .attr("patternTransform", "rotate(45)")
      .append("line")
      .attr("x1", 0)
      .attr("y1", 0)
      .attr("x2", 0)
      .attr("y2", 6)
      .attr("stroke", surface)
      .attr("stroke-width", 2);
    const plot = svg.append("g").attr("clip-path", `url(#abc-x-${uid})`);
    const layers = (clipId, opacity) => {
      const g = plot
        .append("g")
        .attr("clip-path", hideNegative ? `url(#abc-plot-${uid})` : null)
        .append("g")
        .attr("clip-path", `url(#${clipId}-${uid})`);
      const negatives = series.filter((s) => s.some((p) => p.negative));
      g.append("g")
        .selectAll("path")
        .data(series)
        .join("path")
        .attr("data-key", (s) => s.key)
        .attr("d", (s) => area(false)(extendSignRuns(s)))
        .attr("fill", (s) => this.colors[s.key])
        .attr("fill-opacity", opacity)
        .attr("stroke", surface)
        .attr("stroke-width", 1);
      g.append("g")
        .selectAll("path")
        .data(negatives)
        .join("path")
        .attr("data-key", (s) => s.key)
        .attr("d", (s) => area(true)(extendSignRuns(s)))
        .attr("fill", (s) => this.colors[s.key])
        .attr("fill-opacity", Math.min(1, opacity + 0.1))
        .attr("stroke", surface)
        .attr("stroke-width", 1);
      g.append("g")
        .selectAll("path")
        .data(negatives)
        .join("path")
        .attr("data-key", (s) => s.key)
        .attr("d", (s) => area(true)(extendSignRuns(s)))
        .attr("fill", `url(#abc-hatch-${uid})`);
    };
    layers("abc-past", 0.9);
    layers("abc-future", 0.45);
    this.#dayMarkers(svg, x, plotWidth, margin.top, height - AXIS_H);

    svg
      .append("line")
      .attr("x1", margin.left)
      .attr("x2", width - margin.right)
      .attr("y1", y(0))
      .attr("y2", y(0))
      .attr("stroke", "currentColor")
      .attr("stroke-opacity", 0.6);

    const line = d3
      .line()
      .x((row) => x(row.date))
      .y((row) => y(net(row)))
      .curve(d3.curveStepAfter);
    const todayIndex = lineRows.findIndex((row) => +row.date >= +today);
    const past = todayIndex < 0 ? lineRows : lineRows.slice(0, todayIndex + 1);
    const ahead = todayIndex < 0 ? [] : lineRows.slice(todayIndex);
    plot
      .append("path")
      .datum(past)
      .attr("d", line)
      .attr("fill", "none")
      .attr("stroke", ink)
      .attr("stroke-width", 2);
    if (ahead.length > 1) {
      plot
        .append("path")
        .datum(ahead)
        .attr("d", line)
        .attr("fill", "none")
        .attr("stroke", ink)
        .attr("stroke-width", 2)
        .attr("stroke-dasharray", "4 3");
    }

    if (this.horizon && +today >= +domain[0] && +today <= +domain[1]) {
      svg
        .append("line")
        .attr("x1", todayX)
        .attr("x2", todayX)
        .attr("y1", margin.top)
        .attr("y2", height - AXIS_H)
        .attr("stroke", "currentColor")
        .attr("stroke-dasharray", "2 3");
      svg
        .append("text")
        .attr("x", todayX + 4)
        .attr("y", margin.top + 10)
        .style("font-size", "11px")
        .style("fill", "currentColor")
        .text(this.t("today_forecast"));
    }

    const tip = this.#crosshair(
      el,
      svg,
      rows,
      series,
      x,
      y,
      keys,
      net,
      margin,
      width,
      height,
    );
    if (this.showTransactions) {
      this.#drawLane(
        el,
        tip,
        svg,
        keys,
        x,
        height - AXIS_H - LANE_H / 2,
        margin,
        width,
        surface,
        ink,
      );
    }

    if (this.zoom) {
      const format =
        domain[1] - domain[0] < 3 * DAY ? this.timeLabel : this.dayLabel;
      const end =
        format === this.dayLabel ? new Date(+domain[1] - 1) : domain[1];
      const chip = this.#control("zoom");
      chip.querySelector("[data-zoom-range]").textContent =
        `${format(domain[0])} – ${format(end)}`;
      chip
        .querySelector("[data-zoom-reset]")
        .addEventListener("click", () => this.#resetZoom());
      el.append(chip);
    }
  }

  // Minor ticks under the date axis: one per day while days are at least
  // 4px apart, else one per week (Mondays); month starts are taller. Zoomed
  // in to ~30px a day or more, faint midnight lines mark the day bands.
  #dayMarkers(svg, x, plotWidth, top, axisY) {
    const [d0, d1] = x.domain();
    const pxPerDay = plotWidth / ((d1 - d0) / DAY);
    const interval =
      pxPerDay >= 4 ? d3.utcDay : pxPerDay * 7 >= 4 ? d3.utcMonday : null;
    if (!interval) return;
    const marks = interval.range(interval.ceil(d0), new Date(+d1 + 1));
    const g = svg.append("g").style("pointer-events", "none");
    const monthStart = (d) => d.getUTCDate() === 1;
    g.selectAll("line.tick")
      .data(marks)
      .join("line")
      .attr("class", "tick")
      .attr("x1", (d) => x(d))
      .attr("x2", (d) => x(d))
      .attr("y1", axisY)
      .attr("y2", (d) => axisY + (monthStart(d) ? 9 : 5))
      .attr("stroke", "currentColor")
      .attr("stroke-width", (d) => (monthStart(d) ? 1.5 : 1))
      .attr("stroke-opacity", (d) => (monthStart(d) ? 0.9 : 0.6));
    if (interval === d3.utcDay && pxPerDay >= 30) {
      g.selectAll("line.band")
        .data(marks)
        .join("line")
        .attr("class", "band")
        .attr("x1", (d) => x(d))
        .attr("x2", (d) => x(d))
        .attr("y1", top)
        .attr("y2", axisY)
        .attr("stroke", "currentColor")
        .attr("stroke-opacity", 0.14);
    }
  }

  // Date and time within a few days, dates up to ~5 months, months beyond,
  // all in the family's date format.
  #xAxis(x, width) {
    const [a, b] = x.domain();
    const days = (b - a) / DAY;
    const slots = Math.max(2, Math.floor(width / 110));
    if (days <= 3)
      return d3
        .axisBottom(x)
        .ticks(Math.max(2, Math.floor(width / 140)))
        .tickFormat(this.timeLabel);
    if (days <= 150) {
      return d3
        .axisBottom(x)
        .ticks(Math.min(Math.max(2, Math.floor(width / 150)), Math.ceil(days)))
        .tickFormat(this.dayLabel);
    }
    const step =
      [1, 2, 3, 4, 6, 12, 24, 36, 60].find((m) => days / 30.4 / m <= slots) ||
      120;
    return d3
      .axisBottom(x)
      .ticks(d3.utcMonth.every(step))
      .tickFormat(this.monthLabel);
  }

  // Crosshair + tooltip and drag-to-zoom on one surface (d3 brush): drag a
  // range to zoom into it, double-click to reset. Pointing at a layer brings
  // that account forward. Returns the tooltip element for the lane.
  #crosshair(el, svg, rows, series, x, y, keys, net, margin, width, height) {
    const tip = document.createElement("div");
    tip.className = `${CHART_TOOLTIP_CLASSES} opacity-0 top-0 min-w-56`;
    el.append(tip);
    const guide = svg
      .append("line")
      .attr("y1", margin.top)
      .attr("y2", height - margin.bottom)
      .attr("stroke", "currentColor")
      .attr("opacity", 0);
    const dot = svg
      .append("circle")
      .attr("r", 4)
      .attr("fill", getComputedStyle(this.element).color)
      .attr("stroke", this.#surface(el))
      .attr("stroke-width", 2)
      .attr("opacity", 0);
    const names = Object.fromEntries(
      this.chartData.accounts.map((a) => [a.id, a.name]),
    );
    const rowAt = d3.bisector((row) => row.date).right;
    const hide = () => {
      guide.attr("opacity", 0);
      dot.attr("opacity", 0);
      tip.classList.add("opacity-0");
      this.#highlight(null);
    };
    // Negative stretches are drawn on top of the positive stack, so they are hit first.
    const layerAt = (i, v) => {
      const hit = (negative) =>
        series.find(
          (s) =>
            s[i] && s[i].negative === negative && v >= s[i][0] && v <= s[i][1],
        );
      return (hit(true) || hit(false))?.key;
    };

    const brush = d3
      .brushX()
      .extent([
        [margin.left, margin.top],
        [width - margin.right, height - margin.bottom],
      ])
      .on("start", hide)
      .on("end", (event) => {
        if (!event.selection || !event.sourceEvent) return;
        const [a, b] = event.selection;
        brushGroup.call(brush.move, null);
        if (b - a >= 6) this.#setZoom(x.invert(a), x.invert(b));
      });
    const brushGroup = svg.append("g").call(brush);
    brushGroup
      .select(".selection")
      .attr("fill", "currentColor")
      .attr("fill-opacity", 0.12)
      .attr("stroke", "currentColor")
      .attr("stroke-opacity", 0.4);
    brushGroup
      .select(".overlay")
      .style("cursor", "crosshair")
      .on("dblclick", () => this.#resetZoom())
      .on("pointermove.tip", (event) => {
        if (event.buttons) {
          hide();
          return;
        }
        const [mx, my] = d3.pointer(event, svg.node());
        const index = Math.max(0, rowAt(rows, x.invert(mx)) - 1);
        const row = rows[index];
        const under = layerAt(index, y.invert(my));
        this.#highlight(under ? [under] : null);
        guide.attr("x1", mx).attr("x2", mx).attr("opacity", 0.35);
        dot
          .attr("cx", mx)
          .attr("cy", y(net(row)))
          .attr("opacity", 1);
        const ordered = under
          ? [under, ...keys.filter((k) => k !== under)]
          : keys;
        const lines = ordered
          .filter((k) => k === under || Math.abs(row.values[k]) >= 0.5)
          .map((k) => {
            const lead = k === under;
            return `<div class="flex items-center justify-between gap-4 ${lead ? "font-medium text-primary text-sm pb-0.5" : ""}"><span class="flex items-center gap-1.5 min-w-0"><span class="${lead ? "w-2.5 h-2.5" : "w-2 h-2"} rounded-sm shrink-0" style="background:${this.colors[k]}"></span><span class="truncate">${escapeHtml(names[k])}</span></span><span class="tabular-nums">${this.fmt(row.values[k])}</span></div>`;
          });
        const events = row.events
          .filter((e) => keys.includes(e.account))
          .map(
            (e) =>
              `<div class="flex justify-between gap-4 text-xs text-secondary"><span class="truncate">${escapeHtml(e.name)}${
                e.source === "transaction"
                  ? ` (${escapeHtml(this.t("recorded"))})`
                  : ""
              }</span><span class="tabular-nums">${this.fmtSigned(e.amount)}</span></div>`,
          );
        tip.innerHTML = `<div class="${CHART_TOOLTIP_CONTEXT_CLASSES}">${this.dayLabel(row.date)}${row.forecast ? ` · ${escapeHtml(this.t("forecast"))}` : ""}</div>
          <div class="flex justify-between gap-4 mb-1"><span>${escapeHtml(this.t("total"))}</span><span class="${CHART_TOOLTIP_VALUE_CLASSES}">${this.fmt(net(row))}</span></div>
          <div class="space-y-0.5 text-xs">${lines.join("")}</div>
          ${events.length ? `<div class="mt-1 pt-1 border-t border-secondary space-y-0.5">${events.join("")}</div>` : ""}
          <div class="text-xs text-secondary mt-1 pt-1 border-t border-secondary">${escapeHtml(this.t("drag_to_zoom"))}${this.zoom ? ` · ${escapeHtml(this.t("double_click_reset"))}` : ""}</div>`;
        const tipWidth = tip.offsetWidth;
        tip.style.top = "0";
        tip.style.left = `${mx + 12 + tipWidth > width ? mx - tipWidth - 12 : mx + 12}px`;
        tip.classList.remove("opacity-0");
      })
      .on("pointerleave.tip", hide);
    return tip;
  }

  // --- transaction lane ---
  // The endpoint returns at most a few thousand transactions, newest first,
  // with covered_from = the first day it holds completely. The first load
  // asks for the whole range; older days load when the chart is zoomed into
  // them, and merge in.
  async #loadTransactions(range = null) {
    if (this.transactionsLoading) return;
    this.transactionsLoading = true;
    if (!range) this.transactionsState = "loading";
    this.#syncSettings();
    const [start, end] = range || [
      this.chartData.dates[0] || this.chartData.today,
      this.chartData.horizon,
    ];
    try {
      const url = `${this.transactionsUrlValue}?${new URLSearchParams({ start_date: start, end_date: end })}`;
      const response = await fetch(url, {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
      });
      if (!response.ok) throw new Error(String(response.status));
      const body = await response.json();
      this.transactions ||= [];
      this.transactionIds ||= new Set();
      for (const item of body.items) {
        if (!this.transactionIds.has(item.id)) {
          this.transactionIds.add(item.id);
          this.transactions.push(item);
        }
      }
      // A range fetch that cannot move the boundary back (one day holding
      // more than the cap) stops further automatic loading.
      if (range && this.coveredFrom && body.covered_from >= this.coveredFrom)
        this.transactionsStuck = true;
      else this.coveredFrom = body.covered_from;
      this.transactionsState = "ok";
    } catch {
      if (!range) this.transactionsState = "error";
      // No automatic retry: the redraw would ask for the same range again at
      // once. The next zoom change re-arms it.
      else this.transactionsFailed = true;
    }
    this.transactionsLoading = false;
    this.draw();
  }

  #loadOlder(domainStart) {
    if (
      this.transactionsLoading ||
      this.transactionsStuck ||
      this.transactionsFailed ||
      !this.coveredFrom
    )
      return;
    const before = formatDay(new Date(+parseDay(this.coveredFrom) - DAY));
    const from = formatDay(domainStart);
    if (from > before) return;
    setTimeout(() => this.#loadTransactions([from, before]), 0); // not from inside draw()
  }

  // One dot per day, or one per transaction once a day is wide enough on
  // screen (Sure records dates, not times, so a day's transactions are
  // spread evenly across it). Nearby dots group; a group, or a day holding
  // several transactions, zooms in on click and a single transaction opens.
  // Hollow = upcoming bill, filled = recorded transaction.
  #drawLane(el, tip, svg, keys, x, laneY, margin, width, surface, ink) {
    const selected = new Set(keys);
    const [d0, d1] = x.domain();
    const pxPerDay = x(new Date(+d0 + DAY)) - x(d0);
    const perItem = pxPerDay >= ITEM_PX * 2;

    const transactions = (this.transactions || [])
      .filter((t) => selected.has(t.account_id))
      .map((t) => ({ ...t, account: t.account_id }));
    const bills = laneBills(
      this.chartData.accounts,
      selected,
      this.chartData.today,
    );
    const points = buildLanePoints(transactions, bills, perItem).map((p) => ({
      ...p,
      color: p.accounts.length === 1 ? this.colors[p.accounts[0]] : null,
    }));
    const visible = points
      .filter((p) => p.t >= +d0 && p.t <= +d1)
      .map((p) => ({ ...p, x: x(new Date(p.t)) }))
      .sort((a, b) => a.x - b.x || a.planned - b.planned);
    const clusters = clusterByDistance(visible, LANE_GAP);

    // Design-system ink, read off hidden text-secondary / text-subdued elements.
    const muted = getComputedStyle(this.secondaryInkTarget).color; // a day spanning several accounts
    const ring = getComputedStyle(this.subduedInkTarget).color;
    const lane = svg.append("g");
    lane
      .append("line")
      .attr("x1", margin.left)
      .attr("x2", width - margin.right)
      .attr("y1", laneY)
      .attr("y2", laneY)
      .attr("stroke", "currentColor")
      .attr("stroke-opacity", 0.15);
    const guide = svg
      .append("line")
      .attr("y1", margin.top)
      .attr("y2", laneY)
      .attr("stroke", "currentColor")
      .attr("stroke-dasharray", "2 3")
      .attr("opacity", 0)
      .style("pointer-events", "none");
    const hideTip = () => {
      tip.classList.add("opacity-0");
      guide.attr("opacity", 0);
    };

    const loadedFrom = this.coveredFrom ? parseDay(this.coveredFrom) : null;
    if (loadedFrom && +d0 < +loadedFrom) {
      const edge = Math.max(
        margin.left,
        Math.min(width - margin.right, x(loadedFrom)),
      );
      lane
        .append("rect")
        .attr("x", margin.left)
        .attr("y", laneY - 10)
        .attr("width", Math.max(0, edge - margin.left))
        .attr("height", 20)
        .attr("fill", "currentColor")
        .attr("fill-opacity", 0.05);
      const note = this.transactionsLoading
        ? this.t("older_loading")
        : this.transactionsFailed
          ? this.t("older_failed", { date: this.isoLabel(this.coveredFrom) })
          : this.t("older_not_loaded", {
              date: this.isoLabel(this.coveredFrom),
            });
      svg
        .append("text")
        .attr("x", margin.left + 4)
        .attr("y", laneY - 13)
        .style("font-size", "10px")
        .style("opacity", 0.75)
        .style("fill", "currentColor")
        .text(note);
      if (this.zoom) this.#loadOlder(d0);
    }
    if (perItem) {
      svg
        .append("text")
        .attr("x", width - margin.right)
        .attr("y", laneY - 12)
        .attr("text-anchor", "end")
        .style("font-size", "10px")
        .style("opacity", 0.7)
        .style("fill", "currentColor")
        .text(this.t("spread_note"));
    }

    for (const cluster of clusters) {
      const g = lane
        .append("g")
        .attr("transform", `translate(${cluster.x},${laneY})`)
        .style("cursor", "pointer");
      g.append("circle").attr("r", 11).attr("fill", "transparent");
      const single = cluster.members.length === 1 ? cluster.members[0] : null;
      const count = d3.sum(cluster.members, (p) => p.items.length);
      const t0 = d3.min(cluster.members, (p) => p.t0);
      const t1 = d3.max(cluster.members, (p) => p.t1);
      if (single) {
        g.append("circle")
          .attr("r", count > 1 ? 7 : 4.5)
          .attr("fill", single.planned ? surface : single.color || muted)
          .attr("stroke", single.planned ? single.color || ink : surface)
          .attr("stroke-width", 2);
      } else {
        g.append("circle")
          .attr("r", count > 99 ? 11 : 9.5)
          .attr("fill", surface)
          .attr("stroke", ring)
          .attr("stroke-width", 1.5)
          .attr(
            "stroke-dasharray",
            cluster.members.every((p) => p.planned) ? "2 2" : null,
          );
      }
      if (count > 1) {
        g.append("text")
          .text(count > 999 ? "999+" : count)
          .attr("text-anchor", "middle")
          .attr("dy", "0.35em")
          .style("font-size", "9px")
          .style("font-weight", 600)
          .style("pointer-events", "none")
          .style("fill", single && !single.planned ? surface : ink);
      }
      const zoomable = count > 1;
      const recorded = cluster.members.flatMap((p) =>
        p.planned ? [] : p.items,
      );
      const opensOne = single && !zoomable && !single.planned;
      if (opensOne) g.attr("data-transaction-id", single.items[0].id);
      // Zoom while that can still split the group; when it cannot (several
      // items squeezed into the smallest zoom), list them in Transactions.
      const target = zoomable ? zoomTarget(t0, t1, x.domain(), MIN_ZOOM) : null;
      const actionKey = opensOne
        ? "click_open"
        : target
          ? "click_zoom"
          : recorded.length
            ? "click_list"
            : null;
      const show = () => {
        guide.attr("x1", cluster.x).attr("x2", cluster.x).attr("opacity", 0.4);
        if (single)
          this.#itemsTip(
            el,
            tip,
            single,
            cluster.x,
            laneY,
            width,
            actionKey && this.t(actionKey),
          );
        else
          this.#clusterTip(
            el,
            tip,
            cluster,
            laneY,
            width,
            actionKey && this.t(actionKey),
          );
      };
      const activate = () => {
        hideTip();
        if (opensOne) this.#openTransaction(single.items[0]);
        else if (target)
          this.#setZoom(new Date(target[0]), new Date(target[1]));
        else if (recorded.length) this.#openTransactionList(recorded);
      };
      // Keyboard: every dot is a focusable button with a name; Enter or
      // Space does what a click does, and focus shows its tooltip and a ring.
      const focusRing = g
        .append("circle")
        .attr("r", 13)
        .attr("fill", "none")
        .attr("stroke", ink)
        .attr("stroke-width", 2)
        .attr("opacity", 0)
        .style("pointer-events", "none");
      g.attr("tabindex", 0)
        .attr("role", "button")
        .attr("aria-label", this.#laneLabel(cluster, single, actionKey))
        .style("outline", "none")
        .on("pointerenter", show)
        .on("pointerleave", hideTip)
        .on("focus", () => {
          focusRing.attr("opacity", 1);
          show();
        })
        .on("blur", () => {
          focusRing.attr("opacity", 0);
          hideTip();
        })
        .on("click", activate)
        .on("keydown", (event) => {
          if (event.key !== "Enter" && event.key !== " ") return;
          event.preventDefault();
          activate();
        });
    }
  }

  // The accessible name of a lane dot: its date(s), what it holds, and what
  // activating it does.
  #laneLabel(cluster, single, actionKey) {
    const first = cluster.members[0].date;
    const last = cluster.members[cluster.members.length - 1].date;
    const range =
      first === last
        ? this.isoLabel(first)
        : `${this.isoLabel(first)} – ${this.isoLabel(last)}`;
    const items = cluster.members.flatMap((p) => p.items);
    const what =
      single && items.length === 1
        ? `${items[0].name} ${items[0].display ?? this.fmtSigned(items[0].amount)}`
        : this.#countText(cluster);
    return [`${range}: ${what}`, actionKey && this.t(actionKey)]
      .filter(Boolean)
      .join(". ");
  }

  // "3 transactions (1 upcoming bill)", or only the bills when the group
  // holds no recorded transactions.
  #countText(cluster) {
    const bills = cluster.members
      .filter((p) => p.planned)
      .reduce((sum, p) => sum + p.items.length, 0);
    const recorded = cluster.members
      .filter((p) => !p.planned)
      .reduce((sum, p) => sum + p.items.length, 0);
    if (!recorded) return this.tp("upcoming_bills_count", bills);
    return bills
      ? `${this.tp("transactions", recorded)} ${this.tp("bills_suffix", bills)}`
      : this.tp("transactions", recorded);
  }

  // The Transactions list narrowed to these transactions' dates and accounts.
  #openTransactionList(items) {
    const dates = items.map((item) => item.date).sort();
    const params = new URLSearchParams([
      ["q[start_date]", dates[0]],
      ["q[end_date]", dates[dates.length - 1]],
      ...[...new Set(items.map((item) => item.account))].map((id) => [
        "q[account_ids][]",
        id,
      ]),
    ]);
    const dialog = this.element.querySelector("dialog");
    if (dialog?.open) dialog.close();
    window.Turbo.visit(`${this.transactionsIndexUrlValue}?${params}`);
  }

  #itemsTip(el, tip, point, px, laneY, width, action) {
    const names = Object.fromEntries(
      this.chartData.accounts.map((a) => [a.id, a.name]),
    );
    const byAccount = d3.groups(
      point.items.slice(0, TIP_ITEMS),
      (item) => item.account,
    );
    const kind = point.planned
      ? ` · ${escapeHtml(this.tp("upcoming_bills", point.items.length))}`
      : "";
    tip.innerHTML = `<div class="${CHART_TOOLTIP_CONTEXT_CLASSES}">${this.isoLabel(point.date)}${kind}</div>
      <div class="space-y-1.5">${byAccount
        .map(
          ([account, items]) => `<div class="space-y-1">
            <div class="flex items-center gap-1.5 text-xs text-secondary"><span class="w-2 h-2 rounded-sm shrink-0" style="background:${this.colors[account]}"></span>${escapeHtml(names[account] || "")}</div>
            ${items.map((item) => this.#transactionHtml(item, point.planned)).join("")}
          </div>`,
        )
        .join("")}</div>
      ${
        point.items.length > TIP_ITEMS
          ? `<div class="text-xs text-secondary mt-1">${escapeHtml(
              this.t("more_items", {
                count: point.items.length - TIP_ITEMS,
                total_count: point.items.length,
                amount: this.fmtSigned(
                  d3.sum(point.items, (item) => item.amount),
                ),
              }),
            )}</div>`
          : ""
      }
      ${action ? `<div class="text-xs text-secondary mt-1 pt-1 border-t border-secondary">${escapeHtml(action)}</div>` : ""}`;
    this.#placeTip(el, tip, px, laneY, width);
  }

  #clusterTip(el, tip, cluster, laneY, width, action) {
    const items = cluster.members.flatMap((p) => p.items);
    const first = cluster.members[0].date;
    const last = cluster.members[cluster.members.length - 1].date;
    const largest = d3
      .sort(items, (item) => -Math.abs(item.amount))
      .slice(0, 3);
    const countText = this.#countText(cluster);
    const range =
      first === last
        ? this.isoLabel(first)
        : `${this.isoLabel(first)} – ${this.isoLabel(last)}`;
    tip.innerHTML = `<div class="${CHART_TOOLTIP_CONTEXT_CLASSES}">${range}</div>
      <div class="flex justify-between gap-4"><span>${escapeHtml(countText)}</span><span class="${CHART_TOOLTIP_VALUE_CLASSES}">${this.fmtSigned(d3.sum(items, (item) => item.amount))}</span></div>
      <div class="text-xs text-secondary mt-1 space-y-0.5">${largest
        .map(
          (item) =>
            `<div class="flex justify-between gap-4"><span class="truncate max-w-56">${escapeHtml(item.name)}</span><span class="tabular-nums">${item.display === undefined ? this.fmtSigned(item.amount) : escapeHtml(item.display)}</span></div>`,
        )
        .join("")}</div>
      ${action ? `<div class="text-xs text-secondary mt-1 pt-1 border-t border-secondary">${escapeHtml(action)}</div>` : ""}`;
    this.#placeTip(el, tip, cluster.x, laneY, width);
  }

  #placeTip(el, tip, px, laneY, width) {
    tip.classList.remove("opacity-0");
    const tipWidth = tip.offsetWidth;
    const tipHeight = tip.offsetHeight;
    tip.style.left = `${px + 16 + tipWidth > width ? px - tipWidth - 16 : px + 16}px`;
    tip.style.top = `${Math.max(0, Math.min(laneY - tipHeight - 14, el.clientHeight - tipHeight))}px`;
  }

  #transactionHtml(item, planned) {
    const amount = planned
      ? this.fmtSigned(item.amount)
      : escapeHtml(item.display);
    const meta = planned
      ? [this.t("planned_bill")]
      : [item.category, item.merchant, item.kind?.replace(/_/g, " ")].filter(
          Boolean,
        );
    const swatch =
      !planned && item.category_color
        ? `<span class="w-1.5 h-1.5 rounded-full shrink-0" style="background:${escapeHtml(item.category_color)}"></span>`
        : "";
    const detail = [meta.join(" · "), item.notes].filter(Boolean).join(" — ");
    return `<div>
      <div class="flex justify-between gap-4"><span class="truncate font-medium max-w-64">${escapeHtml(item.name)}</span><span class="tabular-nums">${amount}</span></div>
      ${detail ? `<div class="flex items-center gap-1.5 text-xs text-secondary max-w-sm">${swatch}<span class="truncate">${escapeHtml(detail)}</span></div>` : ""}
    </div>`;
  }

  // Opens like a row in the transactions list: in the drawer, over the dashboard.
  #openTransaction(item) {
    const dialog = this.element.querySelector("dialog");
    if (dialog?.open) dialog.close();
    window.Turbo.visit(item.url, { frame: "drawer" });
  }
}

function escapeHtml(value) {
  return String(value).replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
}

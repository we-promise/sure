import { Controller } from "@hotwired/stimulus";
import replaceUrl from "utils/replace_url";

// Searches and filters the rules list in the browser, and folds rule groups.
// Each rule row carries its search text and filter values as data-rule-*
// attributes. While a search or filter is active, groups with matches are
// shown open and dragging is off: with rules hidden, a drop could land
// somewhere the user cannot see.
export default class extends Controller {
  static targets = [
    "input",
    "option",
    "filterButton",
    "badges",
    "badge",
    "rule",
    "group",
    "disclosure",
    "ruleToggle",
    "handle",
    "dragHint",
    "empty",
    "reset",
  ];

  // The server renders the fields from the URL, so a reload keeps them.
  connect() {
    this.filter();
  }

  disconnect() {
    clearTimeout(this.urlSyncTimer);
  }

  filter() {
    const rawQuery = this.inputTarget.value.trim();
    const query = this.#normalize(rawQuery);
    const filters = this.#selectedFilters();
    const filtering =
      rawQuery.length > 0 || Object.values(filters).some((value) => value);
    let visibleCount = 0;

    this.ruleTargets.forEach((rule) => {
      const show = !filtering || this.#matches(rule, rawQuery, query, filters);
      rule.classList.toggle("hidden", !show);
      if (show) visibleCount++;
    });

    this.ruleToggleTargets.forEach((toggle) => {
      const rule = this.#ruleOf(toggle);
      this.#setRuleOpen(rule, filtering || !this.#isCollapsed(rule));
    });

    this.groupTargets.forEach((group) => {
      const hasMatch = this.ruleTargets.some(
        (rule) => group.contains(rule) && !rule.classList.contains("hidden"),
      );
      group.classList.toggle("hidden", filtering && !hasMatch);
      this.#setGroupOpen(group, filtering || !this.#isCollapsed(group));
    });

    this.filtering = filtering;
    this.emptyTarget.classList.toggle("hidden", !filtering || visibleCount > 0);
    this.dragHintTarget.classList.toggle("hidden", !filtering);
    this.resetTarget.classList.toggle("hidden", !filtering);
    this.#updateBadges();
    this.#setDraggable(!filtering);
    this.#scheduleUrlSync();
  }

  // Folding is remembered per device. While filtering, groups are shown open
  // for their matches, so a toggle then only changes the view. Opening a
  // group from this script fires the event too; outside a filter it then
  // stores the state it was set from.
  groupToggled(event) {
    if (this.filtering) return;

    const details = event.currentTarget;
    const group = this.groupTargets.find((target) => target.contains(details));
    if (group) this.#storeCollapsed(group, !details.open);
  }

  #matches(rule, rawQuery, query, filters) {
    // A query that normalizes to nothing (e.g. a lone combining mark) matches
    // no rule rather than every rule.
    if (rawQuery.length > 0) {
      if (query.length === 0) return false;
      if (!this.#normalize(rule.dataset.ruleSearch || "").includes(query)) {
        return false;
      }
    }

    if (
      filters.status &&
      rule.dataset.ruleActive !== String(filters.status === "active")
    ) {
      return false;
    }

    return (
      this.#listIncludes(rule.dataset.ruleActions, filters.action_type) &&
      this.#listIncludes(rule.dataset.ruleConditions, filters.condition_type) &&
      this.#listIncludes(rule.dataset.ruleAccounts, filters.account) &&
      (!filters.group || rule.dataset.ruleGroup === filters.group)
    );
  }

  #listIncludes(list, value) {
    if (!value) return true;
    return (list || "").split(" ").includes(value);
  }

  // Each filter is a radio group whose "all" option has an empty value.
  #selectedFilters() {
    return Object.fromEntries(
      this.#checkedOptions().map((option) => [
        option.dataset.filterParam,
        option.value,
      ]),
    );
  }

  #checkedOptions() {
    return this.optionTargets.filter((option) => option.checked);
  }

  // The badge of a filter names its chosen option; "all" hides it.
  #updateBadges() {
    const chosen = Object.fromEntries(
      this.#checkedOptions()
        .filter((option) => option.value)
        .map((option) => [option.dataset.filterParam, option]),
    );

    this.badgeTargets.forEach((badge) => {
      const option = chosen[badge.dataset.filterParam];
      badge.classList.toggle("hidden", !option);
      badge.querySelector("[data-badge-value]").textContent = option
        ? option.dataset.filterLabel
        : "";
    });
    this.badgesTarget.classList.toggle(
      "hidden",
      Object.keys(chosen).length === 0,
    );
  }

  // The badge's remove button picks the filter's "all" option again. Its
  // badge then hides, so focus moves to the filter button instead of being
  // lost.
  clearFilter(event) {
    const all = this.optionTargets.find(
      (option) =>
        option.dataset.filterParam === event.params.name && !option.value,
    );
    if (all) all.checked = true;
    this.filter();
    this.focusFilterButton();
  }

  // After the popover closes, focus returns to the button that opened it.
  focusFilterButton() {
    this.filterButtonTarget.focus();
  }

  // Enter on a radio would submit the search form and reload the page.
  ignoreEnter(event) {
    event.preventDefault();
  }

  // A rule outside a group folds to its title line; remembered like a group.
  toggleRule(event) {
    const rule = this.#ruleOf(event.currentTarget);
    const open = event.currentTarget.getAttribute("aria-expanded") !== "true";
    if (!this.filtering) this.#storeCollapsed(rule, !open);
    this.#setRuleOpen(rule, open);
  }

  #ruleOf(element) {
    return this.ruleTargets.find((rule) => rule.contains(element));
  }

  #setRuleOpen(rule, open) {
    if (!rule) return;

    const toggle = this.ruleToggleTargets.find((target) =>
      rule.contains(target),
    );
    toggle?.setAttribute("aria-expanded", String(open));
    toggle?.classList.toggle("-rotate-90", !open);
    rule.querySelectorAll("[data-rule-details]").forEach((details) => {
      details.classList.toggle("hidden", !open);
    });
  }

  #setGroupOpen(group, open) {
    const details = this.disclosureTargets.find((target) =>
      group.contains(target),
    );
    if (details) details.open = open;
  }

  #setDraggable(enabled) {
    this.element.querySelectorAll("[draggable]").forEach((item) => {
      item.setAttribute("draggable", String(enabled));
    });
    this.handleTargets.forEach((handle) => {
      handle.classList.toggle("invisible", !enabled);
      handle.disabled = !enabled;
    });
  }

  // Groups and rules outside a group are folded by id.
  #storageKey(element) {
    return element.dataset.groupId
      ? `rule-group-collapsed:${element.dataset.groupId}`
      : `rule-collapsed:${element.dataset.ruleId}`;
  }

  // Storage can be unavailable (private mode, blocked site data); everything
  // then simply starts open.
  #isCollapsed(element) {
    try {
      return localStorage.getItem(this.#storageKey(element)) === "true";
    } catch {
      return false;
    }
  }

  #storeCollapsed(element, collapsed) {
    try {
      if (collapsed) {
        localStorage.setItem(this.#storageKey(element), "true");
      } else {
        localStorage.removeItem(this.#storageKey(element));
      }
    } catch {
      // Not remembered; the fold still applies to this page.
    }
  }

  // Case- and diacritic-insensitive, as in list_filter_controller.
  #normalize(value) {
    return value
      .normalize("NFD")
      .replace(/\p{Mark}/gu, "")
      .toLowerCase();
  }

  // Debounced so a typing burst updates the URL once.
  #scheduleUrlSync() {
    clearTimeout(this.urlSyncTimer);
    this.urlSyncTimer = setTimeout(() => this.#syncUrl(), 200);
  }

  #syncUrl() {
    const params = new URLSearchParams(window.location.search);

    const values = {
      ...this.#selectedFilters(),
      q: this.inputTarget.value.trim(),
    };

    Object.entries(values).forEach(([param, value]) => {
      if (value) {
        params.set(param, value);
      } else {
        params.delete(param);
      }
    });

    const query = params.toString();
    const url = query
      ? `${window.location.pathname}?${query}`
      : window.location.pathname;
    if (url !== `${window.location.pathname}${window.location.search}`) {
      replaceUrl(url);
    }
  }
}

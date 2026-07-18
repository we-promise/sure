import TimeSeriesChartController from "controllers/time_series_chart_controller";

// Net worth chart for the Reports page. Inherits all drawing behavior from
// the time series chart and extends the tooltip with a per-account-group
// breakdown of assets and liabilities at the hovered point.
export default class extends TimeSeriesChartController {
  static values = {
    assetsLabel: { type: String, default: "Assets" },
    liabilitiesLabel: { type: String, default: "Liabilities" },
  };

  _normalizeDataPoints() {
    super._normalizeDataPoints();

    const rawValues = this.dataValue.values || [];
    this._normalDataPoints = this._normalDataPoints.map((point, i) => ({
      ...point,
      assets: rawValues[i]?.assets,
      liabilities: rawValues[i]?.liabilities,
      groups: rawValues[i]?.groups || [],
    }));
  }

  _tooltipTemplate(datum) {
    return `${super._tooltipTemplate(datum)}${this._breakdownTemplate(datum)}`;
  }

  _breakdownTemplate(datum) {
    const assetGroups = datum.groups.filter(
      (group) => group.classification === "asset",
    );
    const liabilityGroups = datum.groups.filter(
      (group) => group.classification === "liability",
    );

    const sections = [
      this._sectionTemplate(this.assetsLabelValue, datum.assets, assetGroups),
      this._sectionTemplate(
        this.liabilitiesLabelValue,
        datum.liabilities,
        liabilityGroups,
      ),
    ]
      .filter(Boolean)
      .join("");

    if (!sections) return "";

    return `<div class="mt-2 pt-2 border-t border-secondary space-y-2">${sections}</div>`;
  }

  _sectionTemplate(label, total, groups) {
    if (groups.length === 0) return "";

    const rows = groups
      .map(
        (group) => `
          <div class="flex items-center justify-between gap-4">
            <div class="flex items-center gap-1.5 text-secondary">
              <span class="w-2 h-2 rounded-full shrink-0" style="background-color: ${group.color};"></span>
              ${group.name}
            </div>
            <span class="text-primary tabular-nums">${this._extractFormattedValue(group.value)}</span>
          </div>
        `,
      )
      .join("");

    return `
      <div class="space-y-1 text-xs">
        <div class="flex items-center justify-between gap-4 font-medium">
          <span class="text-secondary uppercase">${label}</span>
          <span class="text-primary tabular-nums">${this._extractFormattedValue(total)}</span>
        </div>
        ${rows}
      </div>
    `;
  }
}

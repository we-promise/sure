class UI::PeriodPicker < ApplicationComponent
  # Unified time-range selector shared by the dashboard and account charts.
  #
  # Renders a DS::Menu as a flat list of link items — one per Period. Each item
  # is a GET link to `url` carrying `?period=<key>` (plus any `extra_params`),
  # which re-renders `frame` (a Turbo Frame id) with the chosen period. When
  # `frame` is nil the links fall back to a normal Turbo Drive visit.
  #
  # The selected period is marked with a check icon and `aria-current`, and the
  # trigger button shows its label.
  #
  # A custom range (no preset key — e.g. drag-selected on a chart) gets its own
  # trailing row so the list always has exactly one checked item, and the
  # trigger shows the range's actual dates rather than a bare "Custom".
  #
  # NOTE: `url` must be a path without a query string; pass query state via
  # `extra_params` so the picker can compose `?period=…` cleanly.
  attr_reader :selected, :selected_key, :url, :frame, :extra_params, :placement

  def initialize(selected:, url:, frame: nil, extra_params: {}, placement: "bottom-end")
    @selected = selected
    @selected_key = selected.respond_to?(:key) ? selected.key : selected.to_s
    @url = url
    @frame = frame
    @extra_params = (extra_params || {}).symbolize_keys
    @placement = placement
  end

  def periods
    Period.all
  end

  def selected_label
    # A custom range's own label is just "Custom", which says nothing about what
    # the chart is showing. Show the dates instead.
    return selected.label_range if custom_selected?

    # A Period object knows its own label — no need to round-trip through PERIODS.
    selected.respond_to?(:label_short) ? selected.label_short : period_for(selected_key).label_short
  end

  # True when the selection is a Period with no preset key, i.e. an explicit
  # date range (drag-selected on a chart) rather than one of PERIODS.
  def custom_selected?
    selected_key.blank? && selected.is_a?(Period)
  end

  def selected?(key)
    key == selected_key
  end

  def href_for(key)
    "#{url}?#{extra_params.merge(period: key).to_query}"
  end

  # Re-applies the range that is already active. Selecting it is a no-op by
  # design — the row exists to *represent* the current selection in a
  # single-select list, not to introduce a second way to set it.
  def custom_href
    "#{url}?#{extra_params.merge(start_date: selected.start_date, end_date: selected.end_date).to_query}"
  end

  private
    def period_for(key)
      Period.from_key(key)
    rescue Period::InvalidKeyError
      Period.last_30_days
    end
end

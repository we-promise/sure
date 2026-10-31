class UI::CurrencyPicker < ApplicationComponent
  # Report currency selector, the sibling of UI::PeriodPicker on the dashboard.
  #
  # Renders a DS::Menu as a flat list of link items, one per currency the
  # report can be shown in. Each item is a GET link to `url` carrying
  # `?currency=<code>` (plus any `extra_params`), which re-renders `frame` (a
  # Turbo Frame id) with every figure converted to that currency. When `frame`
  # is nil the links fall back to a normal Turbo Drive visit.
  #
  # The trigger shows the selected ISO code alone; the rows add each
  # currency's name so a code the viewer does not know is still recognisable.
  #
  # NOTE: `url` must be a path without a query string; pass query state via
  # `extra_params` so the picker can compose `?currency=…` cleanly.
  attr_reader :selected, :currencies, :url, :frame, :extra_params, :placement

  # `currencies` are Money::Currency objects, in menu order; `selected` is one
  # of them or its ISO code.
  def initialize(selected:, currencies:, url:, frame: nil, extra_params: {}, placement: "bottom-end")
    @selected = selected.respond_to?(:iso_code) ? selected.iso_code : selected.to_s
    @currencies = currencies
    @url = url
    @frame = frame
    @extra_params = (extra_params || {}).symbolize_keys
    @placement = placement
  end

  # [code, label] pairs, in menu order.
  def items
    currencies.map { |currency| [ currency.iso_code, "#{currency.iso_code} · #{currency.name}" ] }
  end

  def selected?(code)
    code == selected
  end

  def href_for(code)
    "#{url}?#{extra_params.merge(currency: code).to_query}"
  end

  # Same history semantics as UI::PeriodPicker: picking a different currency is
  # a new view state and advances, so Back returns to the previous currency;
  # re-picking the checked one changes nothing and replaces.
  def turbo_action_for(item_selected)
    item_selected ? "replace" : "advance"
  end
end

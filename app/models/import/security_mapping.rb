class Import::SecurityMapping < Import::Mapping
  class << self
    def mappables_by_key(import)
      tickers = import.rows.map(&:ticker).compact.map { |t| t.to_s.strip }.reject(&:blank?).uniq

      tickers.index_with do |ticker|
        Security.find_by_ticker_and_exchange(ticker: ticker)
      end
    end
  end

  # Rendered through a provider-backed searchable combobox rather than a static
  # list, so the view does not iterate selectable_values. The already-selected
  # option (if any) is returned so the control can show current state.
  def selectable_values
    return [] unless mappable.present?

    [ [ mappable.name.presence || mappable.ticker, mappable.id ] ]
  end

  def requires_selection?
    true
  end

  def values_count
    import.rows.where(ticker: key).count
  end

  def mappable_class
    Security
  end

  def create_mappable!
    return if value.blank?

    parsed = Security.parse_combobox_id(value)
    return if parsed[:ticker].blank?

    security = Security::Resolver.new(
      parsed[:ticker],
      exchange_operating_mic: parsed[:exchange_operating_mic],
      price_provider: parsed[:price_provider]
    ).resolve

    update!(mappable: security)
  end
end

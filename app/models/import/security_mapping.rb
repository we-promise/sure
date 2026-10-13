class Import::SecurityMapping < Import::Mapping
  validates :mappable, presence: true, if: :requires_selection?

  class << self
    def mappables_by_key(import)
      rows_by_ticker = import.rows.filter_map { |row| row.ticker.to_s.strip.presence && row }
        .group_by { |row| row.ticker.to_s.strip }

      # One query for every candidate ticker, then match in memory, rather than
      # a DB round trip per distinct label (imports can carry thousands of rows).
      candidates = Security.where("UPPER(ticker) IN (?)", rows_by_ticker.keys.map(&:upcase))

      rows_by_ticker.transform_values do |rows|
        mics = rows.map { |row| row.exchange_operating_mic.presence }.uniq

        # Only auto-match when every row for this ticker agrees on a single
        # exchange (or none). An ambiguous ticker is left unmatched so
        # TradeImport#import! falls back to the row-specific resolver.
        next unless mics.size == 1

        match_security(candidates, ticker: rows.first.ticker.to_s.strip, exchange_operating_mic: mics.first)
      end
    end

    private
      def match_security(candidates, ticker:, exchange_operating_mic:)
        matching = candidates.select { |security| security.ticker.to_s.upcase == ticker.upcase }

        if exchange_operating_mic.present?
          mics = Security.exchange_operating_mic_lookup_values(exchange_operating_mic).map(&:upcase)
          matching.find { |security| mics.include?(security.exchange_operating_mic.to_s.upcase) }
        else
          matching.first
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

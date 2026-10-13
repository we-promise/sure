class Import::SecurityMapping < Import::Mapping
  # Every security must resolve to a real Security before the import can be
  # published. Auto-matched rows satisfy this immediately; others require an
  # explicit selection. A brand-new ticker not yet in the local DB is confirmed
  # once via the combobox — the documented tradeoff — rather than silently
  # resolving to an offline, unpriced security.
  validates :mappable, presence: true

  class << self
    # Mappings are keyed by ticker AND exchange, so the same ticker listed on
    # two exchanges stays two distinct mappings and a user selection applies
    # only to its own (ticker, MIC) rows.
    def key_for(ticker:, exchange_operating_mic:)
      symbol = ticker.to_s.strip.upcase
      mic = Security.canonical_exchange_operating_mic(exchange_operating_mic.presence)
      [ symbol, mic ].compact.join("|")
    end

    def mappables_by_key(import)
      rows_by_key = import.rows.filter_map { |row| row.ticker.to_s.strip.present? && row }
        .group_by { |row| key_for(ticker: row.ticker, exchange_operating_mic: row.exchange_operating_mic) }

      # One query for every candidate ticker, then match in memory, rather than
      # a DB round trip per distinct label (imports can carry thousands of rows).
      tickers = rows_by_key.values.map { |rows| rows.first.ticker.to_s.strip.upcase }.uniq
      candidates = Security.where("UPPER(ticker) IN (?)", tickers)

      rows_by_key.transform_values do |rows|
        row = rows.first
        match_security(candidates, ticker: row.ticker, exchange_operating_mic: row.exchange_operating_mic)
      end
    end

    # The security a published trade should use for this row, resolved through
    # its own (ticker, MIC) mapping.
    def mappable_for_row(import, row)
      import.mappings.securities.find_by(key: key_for(ticker: row.ticker, exchange_operating_mic: row.exchange_operating_mic))&.mappable
    end

    private
      def match_security(candidates, ticker:, exchange_operating_mic:)
        # Never auto-match an offline security: an earlier import may have
        # created one whose ticker is the full descriptive label, and matching
        # it would preserve the unpriced holding this step exists to fix.
        matching = candidates.reject(&:offline?)
          .select { |security| security.ticker.to_s.upcase == ticker.to_s.strip.upcase }

        if exchange_operating_mic.present?
          mics = Security.exchange_operating_mic_lookup_values(exchange_operating_mic).map(&:upcase)
          matching.find { |security| mics.include?(security.exchange_operating_mic.to_s.upcase) }
        elsif matching.size == 1
          # No MIC on the row: auto-match only when there is a single local
          # listing. Multiple listings are ambiguous, so defer to the user.
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

  # The row ticker component of this mapping's composite key.
  def ticker
    key.to_s.split("|", 2).first.to_s
  end

  # The MIC component of this mapping's composite key (blank when none).
  def exchange_operating_mic
    key.to_s.split("|", 2)[1].to_s
  end

  # Human-readable label for the CSV-side column: the ticker, with its exchange
  # when the row carried one (so two listings of the same symbol are told apart).
  def display_key
    return "(unassigned)" if ticker.blank?

    exchange_operating_mic.present? ? "#{ticker} (#{Security.exchange_name_for(exchange_operating_mic)})" : ticker
  end

  def values_count
    import.rows.count do |row|
      self.class.key_for(ticker: row.ticker, exchange_operating_mic: row.exchange_operating_mic) == key
    end
  end

  def mappable_class
    Security
  end

  # Securities are user-chosen (or auto-matched), not re-derivable from the CSV
  # text. On a resync (e.g. a row edit), keep an existing selection so editing
  # an unrelated field doesn't wipe the user's mapping; adopt a fresh auto-match
  # only when nothing is selected yet.
  def mappable_for_sync(derived_mappable)
    mappable || derived_mappable
  end

  def create_mappable!
    # No-op on a blank value so an auto-matched mapping (mappable set, value
    # never touched) keeps its security when TradeImport#import! runs this over
    # every mapping. An explicit user clear is handled by the controller, which
    # alone knows a blank was deliberately submitted.
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

  # Explicitly drop the current selection (used when the user clears the
  # combobox). Skips validation so clearing a now-unresolved mapping doesn't
  # error — presence is enforced at the publish gate.
  def clear_selection!
    update_columns(value: nil, mappable_id: nil, mappable_type: nil)
  end
end

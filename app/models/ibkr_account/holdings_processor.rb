class IbkrAccount::HoldingsProcessor
  include IbkrAccount::DataHelpers

  # Categories this importer accepts. STK resolves to an exchange-listed
  # security by symbol. CRYPTO (custodied at Paxos) and CMDTY (spot metals)
  # have no listing to resolve against and carry no securityID, so they are
  # tracked under a namespace of their own.
  UNLISTED_ASSET_CATEGORIES = %w[CRYPTO CMDTY].freeze
  SUPPORTED_ASSET_CATEGORIES = (%w[STK] + UNLISTED_ASSET_CATEGORIES).freeze

  # "CRYPTO:" is the ticker namespace every crypto integration here shares, so
  # a coin lives in one Security row across providers. The prefix is also what
  # keeps the position off an exchange-listed stock of the same symbol, which a
  # bare-symbol lookup would match and then price. Spot metals take the
  # symmetric "CMDTY:".
  TICKER_PREFIXES = { "CRYPTO" => "CRYPTO:", "CMDTY" => "CMDTY:" }.freeze

  # Crypto under this namespace is quotable, and is bound to the provider that
  # quotes it the way Onchain::SecurityResolver binds it, so a row this importer
  # creates first still gets price history for every other integration.
  CRYPTO_PRICE_PROVIDER = "binance_public"

  # Spot metals are quoted by nobody: the statement's mark price is the only
  # price they have. Offline keeps the daily price fetch off them, and the
  # reason says which flow decided that.
  COMMODITY_OFFLINE_REASON = "ibkr_commodity"

  def initialize(ibkr_account)
    @ibkr_account = ibkr_account
  end

  def process
    return unless account.present?

    grouped_positions.each do |(_, _, report_date), group|
      process_group(group, report_date)
    end
  end

  private

    def account
      @ibkr_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def grouped_positions
      Array(@ibkr_account.raw_holdings_payload).each_with_object({}) do |position, groups|
        data = position.with_indifferent_access
        next unless supported_position?(data)

        currency = extract_currency(data, fallback: @ibkr_account.currency)
        report_date = parse_date(data[:report_date]) || @ibkr_account.report_date || Date.current
        key = [ position_key(data), currency, report_date ]
        groups[key] ||= []
        groups[key] << data
      end
    end

    # conid, guaranteed present by supported_position?, identifies a listed
    # position. An unlisted one groups by the ticker it resolves to: IBKR can
    # report one asset under more than one conid, and a holding is keyed on
    # (security, date, currency), so a second group for the same security would
    # overwrite the first instead of summing with it.
    def position_key(row)
      unlisted?(row) ? unlisted_ticker(row) : row[:conid]
    end

    def process_group(rows, report_date)
      sample = rows.first
      price = parse_decimal(sample[:mark_price])
      # quantity and cost_basis are derived from the same set of valid lots so
      # they are always consistent — a lot with an unparseable cost_basis_price
      # is excluded from both counts rather than inflating qty while shrinking basis.
      aggregate = valid_lots(rows)
      return unless price && aggregate

      # Resolved after the price, so a group that cannot be imported does not
      # leave a security behind with no holding on it.
      security = resolve_position_security(sample)
      return unless security

      quantity   = aggregate[:quantity]
      cost_basis = aggregate[:cost_basis]
      amount = quantity * price
      currency = extract_currency(sample, fallback: @ibkr_account.currency)
      external_id = [ "ibkr", @ibkr_account.ibkr_account_id, position_key(sample), report_date, currency ].join("_")

      import_adapter.import_holding(
        security: security,
        quantity: quantity,
        amount: amount,
        currency: currency,
        date: report_date,
        price: price,
        cost_basis: cost_basis,
        external_id: external_id,
        source: "ibkr",
        account_provider_id: @ibkr_account.account_provider&.id,
        delete_future_holdings: false
      )
    end

    # Aggregates only the lots that have both a parseable position and cost_basis_price.
    # Returns { quantity:, cost_basis: } so the caller uses a consistent lot set for
    # both values — a lot skipped here is excluded from quantity too, preventing the
    # case where qty covers more shares than the cost basis was computed from.
    def valid_lots(rows)
      total_quantity = BigDecimal("0")
      total_cost = BigDecimal("0")

      rows.each do |row|
        row_quantity   = parse_decimal(row[:position])
        row_cost_basis = parse_decimal(row[:cost_basis_price])

        unless row_quantity && row_cost_basis
          Rails.logger.warn(
            "IbkrAccount::HoldingsProcessor - Skipping lot with missing position or cost_basis_price " \
            "for conid=#{row[:conid].inspect}"
          )
          next
        end

        total_quantity += row_quantity.abs
        total_cost     += row_quantity.abs * row_cost_basis
      end

      return nil if total_quantity.zero?

      { quantity: total_quantity, cost_basis: total_cost / total_quantity }
    end

    def resolve_position_security(row)
      return resolve_security(row) unless unlisted?(row)

      ticker = unlisted_ticker(row)
      return nil if ticker.blank?

      Security.find_by(ticker: ticker) || create_unlisted_security(ticker, row)
    end

    def unlisted?(row)
      UNLISTED_ASSET_CATEGORIES.include?(row[:asset_category].to_s)
    end

    def unlisted_ticker(row)
      symbol = row[:symbol].to_s.strip.upcase
      return nil if symbol.blank?

      prefix = TICKER_PREFIXES[row[:asset_category].to_s]
      symbol.start_with?(prefix) ? symbol : "#{prefix}#{symbol}"
    end

    # Securities are global, so an existing row is reused exactly as it stands:
    # its price provider and its offline state belong to whichever flow set
    # them. The savepoint is what keeps a lost create race from aborting the
    # surrounding transaction and taking the rest of the import with it.
    def create_unlisted_security(ticker, row)
      Security.transaction(requires_new: true) do
        Security.create!(
          ticker: ticker,
          name: row[:description].presence || ticker,
          **pricing_attributes(row)
        )
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      Security.find_by(ticker: ticker)
    end

    def pricing_attributes(row)
      return { offline: true, offline_reason: COMMODITY_OFFLINE_REASON } unless row[:asset_category].to_s == "CRYPTO"

      {
        exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC,
        price_provider: CRYPTO_PRICE_PROVIDER
      }
    end

    def supported_position?(row)
      SUPPORTED_ASSET_CATEGORIES.include?(row[:asset_category].to_s) &&
        row[:side].to_s == "Long" &&
        row[:conid].present? &&
        # conid identifies an unlisted position; IBKR sends it no securityID.
        (unlisted?(row) || (row[:security_id].present? && row[:security_id_type].present?)) &&
        row[:symbol].present? &&
        row[:currency].present? &&
        row[:fx_rate_to_base].present? &&
        row[:position].present? &&
        row[:mark_price].present? &&
        row[:cost_basis_price].present? &&
        row[:report_date].present?
    end
end

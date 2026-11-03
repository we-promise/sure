class IbkrAccount::HoldingsProcessor
  include IbkrAccount::DataHelpers

  # Only STK was accepted, so a crypto position (custodied at Paxos) or a spot
  # metal was dropped on the way in: the sync counted it among the positions it
  # had processed, the account was short its value, and nothing reached the
  # debug log to say which ones had gone. Neither has an exchange listing to
  # resolve against, so both are imported as offline securities, valued at the
  # mark price the statement already carries for them.
  UNLISTED_ASSET_CATEGORIES = %w[CRYPTO CMDTY].freeze
  SUPPORTED_ASSET_CATEGORIES = (%w[STK] + UNLISTED_ASSET_CATEGORIES).freeze

  # The namespace an unlisted position is tracked under. "CRYPTO:" is the form
  # every crypto integration in this codebase already writes, so an IBKR
  # bitcoin position lands on the same Security row as a Binance or on-chain
  # one -- and, which matters more, not on the exchange-listed stock that
  # trades under the ticker "BTC" and would hand it that stock's prices.
  TICKER_PREFIXES = { "CRYPTO" => "CRYPTO:", "CMDTY" => "CMDTY:" }.freeze

  # Nothing quotes these: the statement's mark price is the only price they
  # will ever have. Left online, each sync would queue a fetch that cannot
  # succeed and count the failure against the security.
  OFFLINE_REASON = "ibkr_unlisted"

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

        # conid is guaranteed present by supported_position?, so no fallbacks needed
        currency = extract_currency(data, fallback: @ibkr_account.currency)
        report_date = parse_date(data[:report_date]) || @ibkr_account.report_date || Date.current
        key = [ data[:conid], currency, report_date ]
        groups[key] ||= []
        groups[key] << data
      end
    end

    def process_group(rows, report_date)
      sample = rows.first
      security = resolve_position_security(sample)
      return unless security

      price = parse_decimal(sample[:mark_price])
      # quantity and cost_basis are derived from the same set of valid lots so
      # they are always consistent — a lot with an unparseable cost_basis_price
      # is excluded from both counts rather than inflating qty while shrinking basis.
      aggregate = valid_lots(rows)
      return unless price && aggregate

      quantity   = aggregate[:quantity]
      cost_basis = aggregate[:cost_basis]
      amount = quantity * price
      currency = extract_currency(sample, fallback: @ibkr_account.currency)
      external_id = [ "ibkr", @ibkr_account.ibkr_account_id, sample[:conid], report_date, currency ].join("_")

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

    # An exchange listing is resolved by symbol, as it always was. Anything
    # unlisted is tracked under its own namespaced ticker, which is also what
    # keeps it from being matched to a stock that trades under the same symbol.
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
      return symbol if symbol.include?(":")

      "#{TICKER_PREFIXES[row[:asset_category].to_s]}#{symbol}"
    end

    # Securities are shared across families, so an existing row is reused as it
    # stands: its price provider and its offline state belong to whichever flow
    # set them, and a crypto integration that has brought "CRYPTO:BTC" online
    # must not have that undone by an IBKR sync.
    #
    # The savepoint is what keeps a lost create race from aborting the
    # surrounding transaction and taking the rest of the import down with it.
    def create_unlisted_security(ticker, row)
      Security.transaction(requires_new: true) do
        Security.create!(
          ticker: ticker,
          name: row[:description].presence || ticker,
          offline: true,
          offline_reason: OFFLINE_REASON
        )
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      Security.find_by(ticker: ticker)
    end

    def supported_position?(row)
      SUPPORTED_ASSET_CATEGORIES.include?(row[:asset_category].to_s) &&
        row[:side].to_s == "Long" &&
        row[:conid].present? &&
        # An unlisted position carries no ISIN or CUSIP, so requiring one was
        # the second reason it was dropped. conid identifies it either way.
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

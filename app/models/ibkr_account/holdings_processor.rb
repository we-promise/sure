class IbkrAccount::HoldingsProcessor
  include IbkrAccount::DataHelpers

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
      security = resolve_security(sample)
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

    def supported_position?(row)
      row[:asset_category].to_s == "STK" &&
        row[:side].to_s == "Long" &&
        row[:conid].present? &&
        row[:security_id].present? &&
        row[:security_id_type].present? &&
        row[:symbol].present? &&
        row[:currency].present? &&
        row[:fx_rate_to_base].present? &&
        row[:position].present? &&
        row[:mark_price].present? &&
        row[:cost_basis_price].present? &&
        row[:report_date].present?
    end
end

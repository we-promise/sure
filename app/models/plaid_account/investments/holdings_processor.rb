class PlaidAccount::Investments::HoldingsProcessor
  # `as_of` is the sync's date. Every holding in the snapshot is dated by it,
  # as the balance anchor is (PlaidAccount::Processor#balance_date).
  def initialize(plaid_account, security_resolver:, as_of: Date.current)
    @plaid_account = plaid_account
    @security_resolver = security_resolver
    @as_of = as_of
  end

  def process
    positions.each_value do |position|
      # A holding can't be negative. A net short only counts in Plaid's
      # account total, as SnaptradeAccount::HoldingsProcessor treats one. A row
      # an earlier sync stored for this date, while the position was long, is
      # closed to zero so the snapshot no longer shows those shares.
      closed_short = position[:quantity].negative?
      next if closed_short && !account.holdings.exists?(security: position[:security], date: as_of, currency: position[:currency])

      import_adapter.import_holding(
        security: position[:security],
        quantity: closed_short ? 0 : position[:quantity],
        amount: closed_short ? 0 : position_amount(position),
        currency: position[:currency],
        date: as_of,
        price: position_price(position),
        account_provider_id: plaid_account.account_provider&.id,
        source: "plaid",
        delete_future_holdings: false  # Plaid doesn't allow holdings deletion
      )
    end
  end

  private
    attr_reader :plaid_account, :security_resolver, :as_of

    # One position per Sure security and currency. A holding is dated by the
    # sync that reported it, as every other provider's is, not by
    # institution_price_as_of: a fund whose NAV is a session behind is still
    # held today, and the account's latest snapshot must include it. Two Plaid
    # holdings the resolver maps to the same security share that date, so
    # they are summed into one row rather than one overwriting the other.
    def positions
      holdings.each_with_object({}) do |plaid_holding, positions|
        resolved_security_result = security_resolver.resolve(plaid_security_id: plaid_holding["security_id"])

        next unless resolved_security_result.security.present?

        security = resolved_security_result.security

        # Parse quantity and price into BigDecimal for proper arithmetic
        quantity_bd = parse_decimal(plaid_holding["quantity"])
        price_bd = parse_decimal(plaid_holding["institution_price"])

        # Skip if essential values are missing
        next if quantity_bd.nil? || price_bd.nil?

        currency = plaid_holding["iso_currency_code"] || account.currency
        # Compute amount using BigDecimal arithmetic to avoid floating point drift
        amount_bd = quantity_bd * price_bd

        position = positions[[ security.id, currency ]] ||=
          { security: security, currency: currency, quantity: 0, price: price_bd, long_quantity: 0, long_amount: 0, long_lots: 0 }
        position[:quantity] += quantity_bd
        next unless quantity_bd.positive?

        position[:price] = price_bd if position[:long_lots].zero?
        position[:long_quantity] += quantity_bd
        position[:long_amount] += amount_bd
        position[:long_lots] += 1
      end
    end

    # One long holding keeps Plaid's exact price (with none, the first
    # holding's price stands). Several are priced at their quantity-weighted
    # average. A short holding's price is left out: netted against a long
    # priced differently it would make the per-share price, and so the value,
    # negative even when shares are still held.
    def position_price(position)
      return position[:price] if position[:long_lots] < 2

      position[:long_amount] / position[:long_quantity]
    end

    # The net quantity at that price, so value and price always agree. With
    # no short holding it is the exact sum of the long holdings' values.
    def position_amount(position)
      return position[:long_amount] if position[:quantity] == position[:long_quantity]

      position[:quantity] * position_price(position)
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      plaid_account.current_account
    end

    def holdings
      plaid_account.raw_holdings_payload&.[]("holdings") || []
    end

    def parse_decimal(value)
      return nil if value.nil?

      case value
      when BigDecimal
        value
      when String
        BigDecimal(value)
      when Numeric
        BigDecimal(value.to_s)
      else
        nil
      end
    rescue ArgumentError => e
      Rails.logger.error("Failed to parse Plaid holding decimal value: #{value.inspect} - #{e.message}")
      nil
    end
end

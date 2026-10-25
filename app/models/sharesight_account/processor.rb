class SharesightAccount::Processor
  # Sharesight's quantities arrive as JSON floats, so units are compared to this
  # many decimal places rather than exactly.
  UNITS_PRECISION = 8

  attr_reader :sharesight_account

  def initialize(sharesight_account)
    @sharesight_account = sharesight_account
  end

  def process
    return unless account.present?

    SharesightAccount::HoldingsProcessor.new(sharesight_account).process

    activities = SharesightAccount::ActivitiesProcessor.new(sharesight_account)
    result = activities.process
    router = SharesightAccount::CashRouter.new(sharesight_account, activities.movements)
    router.route
    SharesightAccount::FundingMirror.new(sharesight_account).mirror

    update_account_balance!

    account.broadcast_sync_complete
    result.merge(notices: router.notices + drift_notices)
  end

  private

    def account
      @account ||= sharesight_account.current_account
    end

    def update_account_balance!
      holdings_value = (sharesight_account.current_balance || 0) - (sharesight_account.cash_balance || 0)
      cash_balance = current_cash
      total_balance = holdings_value + cash_balance

      account.assign_attributes(
        balance: total_balance,
        cash_balance: cash_balance,
        currency: sharesight_account.currency
      )
      account.save!
      account.set_current_balance(total_balance)
    end

    # Zero once the cash lives somewhere else. While the broker has it, either
    # the balance you saw rolled forward through everything booked since, or
    # Sharesight's own cash accounts.
    def current_cash
      return BigDecimal("0") unless sharesight_account.holds_cash_at_broker_on?(Date.current)
      return sharesight_account.cash_balance || BigDecimal("0") unless sharesight_account.cash_anchor?

      moved = account.entries
        .where(entryable_type: %w[Transaction Trade])
        .where(date: (sharesight_account.cash_anchor_on + 1)..Date.current)
        .includes(:entryable)
        .sum(BigDecimal("0")) { |entry| in_portfolio_currency(entry) }
      sharesight_account.cash_anchor_amount - moved
    end

    # A foreign trade is still paid from the portfolio's cash, so convert it with
    # the trade's own rate, or Sure's rate for that day if it doesn't have one.
    def in_portfolio_currency(entry)
      return entry.amount if entry.currency == sharesight_account.currency

      Money.new(entry.amount, entry.currency)
        .exchange_to(sharesight_account.currency, date: entry.date, custom_rate: entry.entryable.try(:exchange_rate))
        .amount
    rescue Money::ConversionError
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "Left #{entry.name} (#{entry.currency}) out of the cash at the broker: no exchange rate for #{entry.date}",
        source: "sharesight",
        family: sharesight_account.sharesight_item.family,
        provider_key: "sharesight"
      )
      BigDecimal("0")
    end

    # Compares the units Sharesight holds with what the trades add up to. A gap
    # usually means a split or transfer we don't book. Skipped with a sync
    # start date, since the older trades are left out on purpose.
    def drift_notices
      return [] if sharesight_account.sync_start_date.present?

      held = Array(sharesight_account.raw_holdings_payload).each_with_object(Hash.new(BigDecimal("0"))) do |holding, units|
        units[holding.dig("instrument", "code").to_s.upcase] += BigDecimal(holding["quantity"].to_s.presence || "0")
      end
      traded = Trade.joins(:entry, :security).where(entries: { account_id: account.id }).group("securities.ticker").sum(:qty)

      (held.keys | traded.keys).sort.filter_map do |ticker|
        held_units = held[ticker].round(UNITS_PRECISION)
        traded_units = (traded[ticker] || BigDecimal("0")).to_d.round(UNITS_PRECISION)
        next if held_units == traded_units

        {
          message: I18n.t("sharesight_accounts.notices.units_drift",
                          account: account.name, ticker: ticker,
                          held: held_units.to_s("F"), traded: traded_units.to_s("F")),
          severity: "warning"
        }
      end
    end
end

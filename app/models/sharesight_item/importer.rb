class SharesightItem::Importer
  include SharesightAccount::DataHelpers

  attr_reader :sharesight_item, :provider

  def initialize(sharesight_item, provider:)
    @sharesight_item = sharesight_item
    @provider = provider
  end

  # Every portfolio gets its value and holdings, since the setup screen shows
  # them. Trades, payouts and cash transactions are only fetched once a
  # portfolio is linked to an account.
  def import
    portfolios = provider.fetch_portfolios
    portfolio_ids = portfolios.filter_map { |portfolio| portfolio["id"]&.to_s.presence }

    portfolios.each do |portfolio|
      import_portfolio(portfolio) if portfolio["id"].present?
    end

    remove_unlinked_portfolios_missing_from(portfolio_ids)
    sharesight_item.update!(status: :good)
  rescue Provider::Sharesight::AuthenticationError
    sharesight_item.update!(status: :requires_update)
    raise
  end

  private

    def import_portfolio(portfolio)
      portfolio_id = portfolio["id"].to_s
      currency = parse_currency(portfolio["currency_code"]) || sharesight_item.family.currency
      report = provider.fetch_performance(portfolio_id)
      holdings = Array(report["holdings"])
      cash = cash_balance(report, currency)

      sharesight_account = sharesight_item.sharesight_accounts.find_or_initialize_by(sharesight_account_id: portfolio_id)
      sharesight_account.assign_attributes(
        name: portfolio["name"].presence || I18n.t("sharesight_items.defaults.portfolio_name", id: portfolio_id),
        currency: currency,
        current_balance: holdings_value(holdings) + cash,
        cash_balance: cash,
        raw_payload: portfolio,
        raw_holdings_payload: holdings
      )

      if sharesight_account.persisted? && sharesight_account.current_account.present?
        trades = provider.fetch_trades(portfolio_id)
        sharesight_account.assign_attributes(
          raw_trades_payload: trades,
          raw_payouts_payload: provider.fetch_payouts(portfolio_id, start_date: payouts_start_date(portfolio, trades)),
          raw_cash_transactions_payload: cash_transactions(portfolio_id, currency)
        )
      end

      sharesight_account.save!
    end

    # The report's value already includes every cash account in any currency,
    # so we add up the holdings ourselves and add the cash we count below.
    def holdings_value(holdings)
      holdings.sum(BigDecimal("0")) { |holding| parse_decimal(holding["value"]) || 0 }
    end

    # Only cash accounts in the portfolio's currency count.
    def cash_balance(report, currency)
      Array(report["cash_accounts"]).sum(BigDecimal("0")) do |cash_account|
        if cash_account_currency(cash_account, currency) == currency
          parse_decimal(cash_account["value"]) || 0
        else
          log_skipped_cash_account(cash_account)
          0
        end
      end
    end

    def cash_transactions(portfolio_id, currency)
      cash_accounts.select { |cash_account| cash_account["portfolio_id"].to_s == portfolio_id }.flat_map do |cash_account|
        next [] unless cash_account_currency(cash_account, currency) == currency

        provider.fetch_cash_account_transactions(cash_account["id"]).map do |transaction|
          transaction.merge("currency" => currency)
        end
      end
    end

    def cash_accounts
      @cash_accounts ||= provider.fetch_cash_accounts
    end

    def cash_account_currency(cash_account, fallback)
      currency = cash_account["currency"]
      currency = currency["code"] if currency.is_a?(Hash)
      parse_currency(currency) || fallback
    end

    # Payouts are fetched by date range, from when the portfolio started (or
    # its first trade if Sharesight doesn't say).
    def payouts_start_date(portfolio, trades)
      parse_date(portfolio["inception_date"]) ||
        trades.filter_map { |trade| parse_date(trade["transaction_date"]) }.min ||
        Date.current
    end

    def remove_unlinked_portfolios_missing_from(portfolio_ids)
      return if portfolio_ids.empty?

      sharesight_item.unlinked_sharesight_accounts.where.not(sharesight_account_id: portfolio_ids).destroy_all
    end

    def log_skipped_cash_account(cash_account)
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "SharesightItem #{sharesight_item.id} - Leaving cash account #{cash_account['id']} out: " \
                 "it isn't in the portfolio's currency",
        source: "sharesight",
        family: sharesight_item.family,
        provider_key: "sharesight"
      )
    end
end

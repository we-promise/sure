# frozen_string_literal: true

class Holding::CashEquivalentBackfill
  Result = Data.define(
    :plaid_holdings,
    :simplefin_holdings,
    :snaptrade_holdings
  ) do
    def total_holdings
      plaid_holdings + simplefin_holdings + snaptrade_holdings
    end
  end

  def self.run(...)
    new(...).run
  end

  def initialize(dry_run: false)
    @dry_run = dry_run
    @counts = Hash.new(0)
  end

  def run
    backfill_snaptrade_holdings
    backfill_plaid_holdings
    backfill_simplefin_holdings

    Result.new(
      plaid_holdings: counts[:plaid_holdings],
      simplefin_holdings: counts[:simplefin_holdings],
      snaptrade_holdings: counts[:snaptrade_holdings]
    )
  end

  private
    attr_reader :counts

    def backfill_snaptrade_holdings
      return unless defined?(SnaptradeAccount)

      SnaptradeAccount.find_each do |snaptrade_account|
        account = snaptrade_account.current_account
        next unless account

        Array(snaptrade_account.raw_holdings_payload).each do |raw_holding|
          holding = normalized_hash(raw_holding)
          next unless holding[:cash_equivalent] == true

          ticker = snaptrade_ticker(holding)
          next if ticker.blank?

          counts[:snaptrade_holdings] += mark_account_security_holdings(
            account,
            ticker: ticker,
            currency: holding_currency(holding)
          )
        end
      rescue => e
        Rails.logger.warn("Holding::CashEquivalentBackfill SnapTrade account #{snaptrade_account.id} skipped: #{e.class} - #{e.message}")
      end
    end

    def backfill_plaid_holdings
      return unless defined?(PlaidAccount)

      PlaidAccount.find_each do |plaid_account|
        account = plaid_account.current_account
        next unless account

        securities = Array(plaid_account.raw_holdings_payload&.dig("securities"))
        securities.each do |raw_security|
          security = normalized_hash(raw_security)
          next unless plaid_cash_equivalent_security?(security)

          ticker = security[:ticker_symbol].presence
          next if ticker.blank? || ticker == "CUR:USD"

          counts[:plaid_holdings] += mark_account_security_holdings(account, ticker: ticker)
        end
      rescue => e
        Rails.logger.warn("Holding::CashEquivalentBackfill Plaid account #{plaid_account.id} skipped: #{e.class} - #{e.message}")
      end
    end

    def backfill_simplefin_holdings
      return unless defined?(SimplefinAccount)

      SimplefinAccount.find_each do |simplefin_account|
        account = simplefin_account.current_account
        next unless account

        Array(simplefin_account.raw_holdings_payload).each do |raw_holding|
          holding = normalized_hash(raw_holding)
          next unless SimplefinAccount::Investments::BalanceCalculator.cash_equivalent?(
            symbol: holding[:symbol],
            description: holding[:description]
          )

          counts[:simplefin_holdings] += mark_simplefin_holding(account, holding)
        end
      rescue => e
        Rails.logger.warn("Holding::CashEquivalentBackfill SimpleFIN account #{simplefin_account.id} skipped: #{e.class} - #{e.message}")
      end
    end

    def mark_simplefin_holding(account, raw_holding)
      external_id = raw_holding[:id].presence

      if external_id.present?
        scope = account.holdings.where(external_id: "simplefin_#{external_id}")
        marked = mark_scope(scope)
        return marked if marked.positive?
      end

      ticker = raw_holding[:symbol].presence
      return 0 if ticker.blank?

      mark_account_security_holdings(
        account,
        ticker: ticker,
        currency: raw_holding[:currency].presence
      )
    end

    def mark_account_security_holdings(account, ticker:, currency: nil)
      security_ids = Security.where("UPPER(ticker) = ?", ticker.to_s.upcase).pluck(:id)
      return 0 if security_ids.empty?

      scope = account.holdings.where(cash_equivalent: false)
      scope = scope.where(currency: currency) if currency.present?
      scope = scope.where(security_id: security_ids).or(scope.where(provider_security_id: security_ids))

      mark_scope(scope)
    end

    def mark_scope(scope)
      relation = scope.where(cash_equivalent: false)
      count = relation.count
      relation.update_all(cash_equivalent: true) unless @dry_run || count.zero?
      count
    end

    def plaid_cash_equivalent_security?(security)
      security[:type] == "cash" || security[:is_cash_equivalent] == true
    end

    def snaptrade_ticker(holding)
      symbol_wrapper = normalized_hash(holding[:symbol])
      symbol_data = normalized_hash(symbol_wrapper[:symbol])
      ticker = symbol_data[:symbol]
      ticker = symbol_data[:raw_symbol] if ticker.is_a?(Hash)
      ticker.to_s.presence
    end

    def holding_currency(holding)
      currency = holding[:currency]
      return currency[:code].presence if currency.is_a?(Hash)

      currency.to_s.presence
    end

    def normalized_hash(value)
      value.is_a?(Hash) ? value.with_indifferent_access : {}.with_indifferent_access
    end
end

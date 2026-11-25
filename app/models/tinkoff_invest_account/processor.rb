class TinkoffInvestAccount::Processor
  class PartialProcessingError < StandardError; end

  attr_reader :tinkoff_invest_account

  def initialize(tinkoff_invest_account)
    @tinkoff_invest_account = tinkoff_invest_account
  end

  def process
    return { holdings: 0, trades: 0, transactions: 0 } unless account.present?

    date = Date.current

    total_balance = update_account_balance!
    holdings_processor = TinkoffInvestAccount::HoldingsProcessor.new(tinkoff_invest_account)
    holdings_count = holdings_processor.process

    activities_processor = TinkoffInvestAccount::ActivitiesProcessor.new(tinkoff_invest_account)
    activity_counts = activities_processor.process

    account.set_current_balance(total_balance, date: date)
    account.broadcast_sync_complete

    if holdings_processor.failed? || activities_processor.failed_operations.any?
      raise PartialProcessingError,
        "Partial processing failure for T-Invest account #{tinkoff_invest_account.id} " \
        "(failed_holdings=#{holdings_processor.failed?}, failed_operations=#{activities_processor.failed_operations.size})"
    end

    advance_sync_checkpoint!

    activity_counts.merge(holdings: holdings_count)
  end

  private

    def account
      @account ||= tinkoff_invest_account.current_account
    end

    def advance_sync_checkpoint!
      payload = tinkoff_invest_account.raw_portfolio_payload
      fetched_at = parse_checkpoint_time(payload.is_a?(Hash) ? payload["_fetched_at"] : nil) || Time.current
      pending_cursor = payload.is_a?(Hash) ? payload["_pending_cursor"].presence : nil

      tinkoff_invest_account.update!(
        last_synced_at: fetched_at,
        operations_cursor: pending_cursor || tinkoff_invest_account.operations_cursor,
        raw_operations_payload: []
      )
    end

    def parse_checkpoint_time(raw)
      return nil if raw.blank?

      Time.iso8601(raw.to_s).utc
    rescue ArgumentError
      nil
    end

    def update_account_balance!
      total_balance = tinkoff_invest_account.current_balance || BigDecimal("0")
      cash_balance = tinkoff_invest_account.cash_balance || BigDecimal("0")

      account.assign_attributes(
        balance: total_balance,
        cash_balance: cash_balance,
        currency: tinkoff_invest_account.currency
      )
      account.save!

      total_balance
    end
end

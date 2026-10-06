class Balance::Materializer
  # Upsert in chunks so that the intermediate attribute-hash array doesn't sit
  # in memory alongside the full @balances array. Reduces peak RSS during sync
  # for accounts with multi-year history.
  PERSIST_BATCH_SIZE = 2_000

  attr_reader :account, :strategy, :security_ids

  # Choose an incremental window that preserves earlier imported account history.
  def initialize(account, strategy:, security_ids: nil, window_start_date: nil)
    @account = account
    @strategy = strategy
    @security_ids = security_ids
    @window_start_date = account.materialization_window(window_start_date)
  end

  # Serialize mixed-account publication and persist holdings and balances atomically.
  def materialize_balances
    Balance.transaction do
      account.lock! if account.accounting_start_date
      materialize_holdings
      capture_provider_cash
      calculate_balances

      Rails.logger.info("Persisting #{@balances.size} balances")
      persist_balances

      purge_stale_balances

      if strategy == :forward
        update_account_info
      end
    end
  end

  private
    # Convert full-provider totals to cash after their holdings are imported,
    # excluding positions managed by separate publishers from the subtraction.
    def capture_provider_cash
      return unless (start_date = account.accounting_start_date)

      full_ids = account.account_providers.reject { |link| link.adapter&.position_only? }.map(&:id)
      cache = Balance::SyncCache.new(account)
      reported = account.entries.valuations.where(source: "provider_balance", date: start_date..Date.current).includes(:entryable)
      reported.each do |entry|
        amount = entry.amount_money.exchange_to(account.currency, date: entry.date).amount
        holdings_value = account.holdings.where(account_provider_id: full_ids, date: entry.date).sum do |holding|
          holding.amount_money.exchange_to(account.currency, date: entry.date).amount
        end
        existing = account.entries.valuations.find_by(date: entry.date, entryable_id: Valuation.cash_anchor.select(:id))
        if existing
          existing.update!(amount: amount - holdings_value, currency: account.currency, source: "provider_cash")
          existing.entryable.update!(cash_entry_total: nil)
          entry.destroy!
        else
          entry.entryable.update!(kind: :cash_anchor, cash_entry_total: nil)
          entry.update!(amount: amount - holdings_value, currency: account.currency, source: "provider_cash",
            name: I18n.t("valuations.cash_anchor", locale: account.family.locale))
        end
      end
      account.valuations.cash_anchor.where(cash_entry_total: nil).includes(:entry).each do |anchor|
        anchor.update!(cash_entry_total: cache.cash_entry_total(anchor.entry.date))
      end
      account.reset_current_anchor_cache!
    end

    # Pass the same security filter and history window to the shared holding materializer.
    def materialize_holdings
      @holdings = Holding::Materializer.new(account, strategy: strategy, security_ids: security_ids,
        window_start_date: @window_start_date).materialize_holdings
    end

    def update_account_info
      # Query fresh balance from DB to get generated column values
      current_balance = account.balances
        .where(currency: account.currency)
        .order(date: :desc)
        .first

      if current_balance
        calculated_balance = current_balance.end_balance
        calculated_cash_balance = current_balance.end_cash_balance
      else
        # Fallback if no balance exists
        calculated_balance = 0
        calculated_cash_balance = 0
      end

      Rails.logger.info("Balance update: cash=#{calculated_cash_balance}, total=#{calculated_balance}")

      account.update!(
        balance: calculated_balance,
        cash_balance: calculated_cash_balance
      )
    end

    # Retain only calculated rows in the requested mixed-account write window.
    def calculate_balances
      @balances = calculator.calculate
      @balances.select! { |balance| balance.date >= @window_start_date } if account.accounting_start_date && @window_start_date
    end

    def persist_balances
      current_time = Time.now
      @balances.each_slice(PERSIST_BATCH_SIZE) do |slice|
        account.balances.upsert_all(
          slice.map { |b| b.to_h.except(:account).transform_keys(&:to_s).merge("updated_at" => current_time) },
          unique_by: %i[account_id date currency]
        )
      end
    end

    # Remove stale tails while preserving valid history before an incremental window.
    def purge_stale_balances
      if @balances.empty?
        # In incremental forward-sync, even when no balances were calculated for the window
        # (e.g. window_start_date is beyond the last entry), purge stale tail records that
        # now fall beyond the prior-balance boundary so orphaned future rows are cleaned up.
        if strategy == :forward && calculator.incremental? && calculator.calculation_start_date <= @window_start_date - 1
          deleted_count = account.balances.delete_by(
            "date < ? OR date > ?",
            calculator.calculation_start_date,
            @window_start_date - 1
          )
          Rails.logger.info("Purged #{deleted_count} stale balances") if deleted_count > 0
        end
        return
      end

      oldest_balance, newest_balance = @balances.minmax_by(&:date)
      newest_calculated_balance_date = newest_balance.date

      # In incremental forward-sync mode the calculator only recalculates from
      # window_start_date onward, so balances before that date are still valid.
      # Use calculation_start_date as the lower purge bound to preserve them —
      # this is the same lower bound the calculator uses, so pre-anchor balances
      # (from entries dated before the opening anchor) are not deleted.
      # We ask the calculator whether it actually ran incrementally — it may have
      # fallen back to a full recalculation, in which case we use the normal bound.
      oldest_valid_date = if account.accounting_start_date
        account.balances.minimum(:date) || oldest_balance.date
      elsif strategy == :forward && calculator.incremental?
        calculator.calculation_start_date
      else
        oldest_balance.date
      end

      deleted_count = account.balances.delete_by("date < ? OR date > ?", oldest_valid_date, newest_calculated_balance_date)
      Rails.logger.info("Purged #{deleted_count} stale balances") if deleted_count > 0
    end

    def calculator
      @calculator ||= if strategy == :reverse
        Balance::ReverseCalculator.new(account)
      else
        Balance::ForwardCalculator.new(account, window_start_date: @window_start_date)
      end
    end
end

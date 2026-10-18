class Balance::Materializer
  # Upsert in chunks so that the intermediate attribute-hash array doesn't sit
  # in memory alongside the full @balances array. Reduces peak RSS during sync
  # for accounts with multi-year history.
  PERSIST_BATCH_SIZE = 2_000

  attr_reader :account, :strategy, :security_ids

  def initialize(account, strategy:, security_ids: nil, window_start_date: nil)
    @account = account
    @strategy = strategy
    @security_ids = security_ids
    @window_start_date = window_start_date
  end

  def materialize_balances
    Balance.transaction do
      materialize_holdings
      calculate_balances

      Rails.logger.info("Persisting #{@balances.size} balances")
      persist_balances

      purge_stale_balances

      if strategy == :forward
        update_account_info
      elsif holdings_from_trades?
        update_cash_balance
      end
    end
  end

  private
    def materialize_holdings
      @holdings = Holding::Materializer.new(account, strategy: holdings_strategy, security_ids: security_ids).materialize_holdings
    end

    # The reverse holdings calculator works back from a provider's holdings
    # snapshot. A linked account whose provider sends balances but no positions
    # has none, so its recorded trades would never become holdings. Those come
    # from the trades instead, as for a manual account, while the balance stays
    # anchored on the provider's figure.
    def holdings_strategy
      holdings_from_trades? ? :forward : strategy
    end

    def holdings_from_trades?
      return @holdings_from_trades if defined?(@holdings_from_trades)

      @holdings_from_trades = strategy == :reverse && account.latest_provider_holdings_snapshot_date.nil?
    end

    # The provider set cash_balance to the whole balance, as it sent no
    # holdings. Once holdings come from trades, cash is what they leave of the
    # provider's balance. Only cash is written: the balance stays the provider's.
    def update_cash_balance
      return unless account.trades.exists?

      current_balance = account.balances.where(currency: account.currency).order(date: :desc).first
      return unless current_balance

      Rails.logger.info("Cash balance from trade-derived holdings: cash=#{current_balance.end_cash_balance}")
      account.update!(cash_balance: current_balance.end_cash_balance)
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

    def calculate_balances
      @balances = calculator.calculate
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
      oldest_valid_date = if strategy == :forward && calculator.incremental?
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

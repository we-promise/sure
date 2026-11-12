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
      @had_derived_position = derived_position?
      @had_calculated_position = calculated_position?
      clear_derived_holdings
      materialize_holdings
      calculate_balances

      Rails.logger.info("Persisting #{@balances.size} balances")
      persist_balances

      purge_stale_balances

      if strategy == :forward
        update_account_info
      elsif holdings_from_trades?
        update_cash_balance
      elsif @had_derived_position
        account.update!(cash_balance: account.balance)
      end
    end
  end

  private
    # The reverse holdings calculator works back from a provider's holdings
    # snapshot. A linked account whose provider sends balances but no positions
    # has none, so its recorded trades would never become holdings. Those come
    # from the trades instead, as for a manual account, while the balance stays
    # anchored on the provider's figure. A security whose trade history is
    # incomplete stays on the reverse path, as it would without the fallback.
    def materialize_holdings
      unless holdings_from_trades?
        @holdings = Holding::Materializer.new(account, strategy: strategy, security_ids: security_ids).materialize_holdings
        return
      end

      built = trade_built_holdings.reject { |holding| incomplete_security_ids.include?(holding.security_id) }
      built = built.select { |holding| security_ids.include?(holding.security_id) } if security_ids
      @holdings = Holding::Materializer.new(
        account, strategy: :forward, security_ids: security_ids, calculated_holdings: built
      ).materialize_holdings

      reverse_ids = incomplete_security_ids_in_scope
      Holding::Materializer.new(account, strategy: :reverse, security_ids: reverse_ids).materialize_holdings if reverse_ids.any?
    end

    # True when at least one traded security builds from its trades, or when
    # there are no trades left, so the fallback's own rows are purged.
    def holdings_from_trades?
      return @holdings_from_trades if defined?(@holdings_from_trades)

      @holdings_from_trades = trade_fallback_eligible? && (
        !account.trades.exists? ||
        (account.trades.distinct.pluck(:security_id) - incomplete_security_ids.to_a).any?
      )
    end

    def trade_fallback_eligible?
      strategy == :reverse && account.latest_provider_holdings_snapshot_date.nil?
    end

    # The forward calculation over the whole account, run once per
    # materialization: it decides which securities are complete and supplies
    # their holdings.
    def trade_built_holdings
      @trade_built_holdings ||= account.trades.exists? ? Holding::ForwardCalculator.new(account).calculate : []
    end

    # A provider's trade history can begin after a position was opened (Plaid
    # sends at most two years), so a sell can arrive without its buy. Built from
    # zero that goes negative, on the latest day or on any day before a later
    # buy. Read from the forward calculator itself, not a sum of trade
    # quantities, so a split between trades is applied. Judged per security:
    # one security's gap says nothing about another's history.
    def incomplete_security_ids
      @incomplete_security_ids ||= trade_built_holdings.select { |holding| holding.qty.negative? }.map(&:security_id).to_set
    end

    def incomplete_security_ids_in_scope
      ids = incomplete_security_ids.to_a
      security_ids ? ids & security_ids : ids
    end

    # Whether a linked account without a provider snapshot holds a position
    # this fallback built: a latest non-provider row with a quantity. Read
    # before materializing, whichever way the fallback then goes. The reverse
    # path's own rows end at zero, so they do not count.
    def derived_position?
      strategy == :reverse && account.latest_provider_holdings_snapshot_date.nil? && account.current_holdings.exists?
    end

    # Any non-provider row with a quantity, on any day. Wider than
    # derived_position?: a position the fallback built and then closed ends on
    # a zero row that current_holdings leaves out, yet the cash it wrote came
    # from a day the position was open. Read only once no trade is left, where
    # the purge clears these rows and nothing is left for cash to exclude.
    def calculated_position?
      strategy == :reverse && account.latest_provider_holdings_snapshot_date.nil? &&
        account.holdings.where(account_provider_id: nil).where.not(qty: 0).exists?
    end

    # Where the fallback stands aside for a position it had built, the reverse
    # path would read that position back as the provider's snapshot and keep
    # it. Clearing the rows first leaves the account as it reads without the
    # fallback: the whole account when no security builds from trades (cash
    # then goes back to the provider's balance), otherwise only the securities
    # with incomplete history.
    #
    # A row with a locked cost basis carries a figure the user entered, which
    # nothing can rebuild. It stays, at a zero quantity so it reads as no
    # position, and the rows later written onto its date keep that figure.
    def clear_derived_holdings
      scope = account.holdings.where(account_provider_id: nil)
      if holdings_from_trades?
        ids = incomplete_security_ids_in_scope
        return if ids.empty?

        scope = scope.where(security_id: ids)
      else
        return unless @had_derived_position

        # A run scoped to some securities clears only theirs.
        scope = scope.where(security_id: security_ids) if security_ids
      end

      scope.where(cost_basis_locked: true).update_all(qty: 0, amount: 0, updated_at: Time.current)
      scope.where(cost_basis_locked: false).delete_all
      account.holdings.reset
    end

    # The provider set cash_balance to the whole balance, as it sent no
    # holdings. Once holdings come from trades, cash is what they leave of the
    # provider's balance. Only cash is written: the balance stays the provider's.
    # When the last trade goes, the purge has cleared the position it built, so
    # cash is the provider's whole balance again. An account that never had a
    # calculated holding keeps the provider's cash untouched.
    def update_cash_balance
      unless account.trades.exists?
        account.update!(cash_balance: account.balance) if @had_derived_position || @had_calculated_position
        return
      end

      current_balance = account.balances
        .where(currency: account.currency)
        .where(date: ..Date.current)
        .order(date: :desc)
        .first
      return unless current_balance

      Rails.logger.info("Cash balance set from trade-derived holdings for account #{account.id}")
      account.update!(cash_balance: current_balance.end_cash_balance)
    end

    def update_account_info
      # Query fresh balance from DB to get generated column values.
      # Excludes future-dated rows defensively: purge_stale_balances should
      # already remove any balance row beyond the freshly calculated range,
      # but if a scheduled (future-dated) row ever survives (e.g. a race
      # between overlapping incremental syncs), account.balance must never
      # surface it as the *current* balance. See Entry#scheduled?.
      current_balance = account.balances
        .where(currency: account.currency)
        .where(date: ..Date.current)
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

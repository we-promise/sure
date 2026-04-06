# "Materializes" holdings (similar to a DB materialized view, but done at the app level)
# into a series of records we can easily query and join with other data.
class Holding::Materializer
  def initialize(account, strategy:, security_ids: nil)
    @account = account
    @strategy = strategy
    @security_ids = security_ids
  end

  def materialize_holdings
    calculate_holdings

    Rails.logger.info("Persisting #{@holdings.size} holdings")
    persist_holdings

    if strategy == :forward && security_ids.nil?
      purge_stale_holdings
    end

    # Clean up only calculated holdings that are directly shadowed by a provider snapshot
    # on the same date/security/currency. Historical calculated rows for provider-linked
    # securities are still needed to derive sane balance charts between sync snapshots.
    cleanup_shadowed_calculated_holdings

    # Also remove calculated rows on the provider's latest snapshot date when those
    # securities are no longer present in the provider payload. This keeps "current"
    # holdings/balance composition aligned with the provider snapshot while preserving
    # older calculated history.
    cleanup_stale_calculated_rows_on_latest_provider_snapshot

    # Reload holdings association to clear any cached stale data
    # This ensures subsequent Balance calculations see the fresh holdings
    account.holdings.reload

    @holdings
  end

  private
    attr_reader :account, :strategy, :security_ids

    def calculate_holdings
      @holdings = calculator.calculate
    end

    def persist_holdings
      return if @holdings.empty?

      current_time = Time.now

      # Load existing holdings to check locked status and source priority
      existing_holdings_map = load_existing_holdings_map

      # Separate holdings into categories based on cost_basis reconciliation
      holdings_to_upsert_with_cost = []
      holdings_to_upsert_without_cost = []

      @holdings.each do |holding|
        key = holding_key(holding)
        existing = existing_holdings_map[key]

        # Skip provider-sourced holdings - they have authoritative data from the provider
        # (e.g., Coinbase, SimpleFIN) and should not be overwritten by calculated holdings
        if existing&.account_provider_id.present?
          Rails.logger.debug(
            "Holding::Materializer - Skipping provider-sourced holding id=#{existing.id} " \
            "security_id=#{existing.security_id} date=#{existing.date}"
          )
          next
        end

        reconciled = Holding::CostBasisReconciler.reconcile(
          existing_holding: existing,
          incoming_cost_basis: holding.cost_basis,
          incoming_source: "calculated"
        )

        base_attrs = holding.attributes
          .slice("date", "currency", "qty", "price", "amount", "security_id")
          .merge("account_id" => account.id, "updated_at" => current_time)

        if existing&.cost_basis_locked?
          # For locked holdings, preserve ALL cost_basis fields
          holdings_to_upsert_without_cost << base_attrs
        elsif reconciled[:should_update] && reconciled[:cost_basis].present?
          # Update with new cost_basis and source
          holdings_to_upsert_with_cost << base_attrs.merge(
            "cost_basis" => reconciled[:cost_basis],
            "cost_basis_source" => reconciled[:cost_basis_source]
          )
        else
          # No cost_basis to set, or existing is better - don't touch cost_basis fields
          holdings_to_upsert_without_cost << base_attrs
        end
      end

      # Upsert with cost_basis updates
      if holdings_to_upsert_with_cost.any?
        account.holdings.upsert_all(
          holdings_to_upsert_with_cost,
          unique_by: %i[account_id security_id date currency]
        )
      end

      # Upsert without cost_basis (preserves existing)
      if holdings_to_upsert_without_cost.any?
        account.holdings.upsert_all(
          holdings_to_upsert_without_cost,
          unique_by: %i[account_id security_id date currency]
        )
      end
    end

    def load_existing_holdings_map
      # Load holdings that might affect reconciliation:
      # - Locked holdings (must preserve their cost_basis)
      # - Holdings with a source (need to check priority)
      # - Provider-sourced holdings (must not be overwritten)
      account.holdings
        .where(cost_basis_locked: true)
        .or(account.holdings.where.not(cost_basis_source: nil))
        .or(account.holdings.where.not(account_provider_id: nil))
        .index_by { |h| holding_key(h) }
    end

    # Remove only calculated holdings that collide with an authoritative provider snapshot
    # on the exact same key. This preserves reverse-calculated history for linked accounts.
    def cleanup_shadowed_calculated_holdings
      deleted_count = account.holdings
        .where(account_provider_id: nil)
        .where(<<~SQL)
          EXISTS (
            SELECT 1
            FROM holdings provider_holdings
            WHERE provider_holdings.account_id = holdings.account_id
              AND provider_holdings.security_id = holdings.security_id
              AND provider_holdings.date = holdings.date
              AND provider_holdings.currency = holdings.currency
              AND provider_holdings.account_provider_id IS NOT NULL
          )
        SQL
        .delete_all

      Rails.logger.info("Cleaned up #{deleted_count} calculated holdings shadowed by provider snapshots") if deleted_count > 0
    end

    def cleanup_stale_calculated_rows_on_latest_provider_snapshot
      provider_snapshot_date = account.latest_provider_holdings_snapshot_date
      return unless provider_snapshot_date

      provider_security_ids = account.holdings
        .where.not(account_provider_id: nil)
        .where(date: provider_snapshot_date)
        .distinct
        .pluck(:security_id)

      scope = account.holdings
        .where(account_provider_id: nil, date: provider_snapshot_date)

      scope = if provider_security_ids.any?
        scope.where.not(security_id: provider_security_ids)
      else
        scope
      end

      deleted_count = scope.delete_all
      Rails.logger.info("Cleaned up #{deleted_count} stale calculated holdings on latest provider snapshot date") if deleted_count > 0
    end

    def holding_key(holding)
      [ holding.account_id || account.id, holding.security_id, holding.date, holding.currency ]
    end

    def purge_stale_holdings
      portfolio_security_ids = account.entries.trades.map { |entry| entry.entryable.security_id }.uniq

      # Never delete provider-sourced holdings - they're authoritative from the provider
      # If there are no securities in the portfolio, only delete non-provider holdings
      if portfolio_security_ids.empty?
        Rails.logger.info("Clearing non-provider holdings (no securities from trades)")
        account.holdings.where(account_provider_id: nil).delete_all
      else
        # Keep provider holdings and holdings for known securities within date range
        deleted_count = account.holdings
          .where(account_provider_id: nil)
          .delete_by("date < ? OR security_id NOT IN (?)", account.start_date, portfolio_security_ids)
        Rails.logger.info("Purged #{deleted_count} stale holdings") if deleted_count > 0
      end
    end

    def calculator
      if strategy == :reverse
        portfolio_snapshot = Holding::PortfolioSnapshot.new(account)
        Holding::ReverseCalculator.new(account, portfolio_snapshot: portfolio_snapshot, security_ids: security_ids)
      else
        Holding::ForwardCalculator.new(account, security_ids: security_ids)
      end
    end
end

# "Materializes" holdings (similar to a DB materialized view, but done at the app level)
# into a series of records we can easily query and join with other data.
class Holding::Materializer
  def initialize(account, strategy:)
    @account = account
    @strategy = strategy
  end

  def materialize_holdings
    calculate_holdings

    Rails.logger.info("Persisting #{@holdings.size} holdings")
    persist_holdings

    if strategy == :forward
      purge_stale_holdings
    end

    # Clean up calculated holdings for securities that now have provider-sourced holdings
    # This prevents duplicates when a manually-entered account gets linked to a provider
    cleanup_calculated_holdings_for_provider_securities

    # Reload holdings association to clear any cached stale data
    # This ensures subsequent Balance calculations see the fresh holdings
    account.holdings.reload

    @holdings
  end

  private
    attr_reader :account, :strategy

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
        # Skip securities that have provider-sourced holdings - don't overwrite provider data
        next if provider_sourced_security_ids.include?(holding.security_id)

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

    # Get security IDs that have provider-sourced holdings (any date)
    # These should be preserved and not overwritten by calculated holdings
    def provider_sourced_security_ids
      @provider_sourced_security_ids ||= account.holdings
        .where.not(account_provider_id: nil)
        .distinct
        .pluck(:security_id)
    end

    # Remove calculated holdings (account_provider_id IS NULL) for securities
    # that now have provider-sourced holdings. This prevents duplicates when
    # a manually-entered account gets linked to a provider.
    def cleanup_calculated_holdings_for_provider_securities
      return if provider_sourced_security_ids.empty?

      deleted_count = account.holdings
        .where(account_provider_id: nil)
        .where(security_id: provider_sourced_security_ids)
        .delete_all

      Rails.logger.info("Cleaned up #{deleted_count} calculated holdings for provider-sourced securities") if deleted_count > 0
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
        Holding::ReverseCalculator.new(account, portfolio_snapshot: portfolio_snapshot)
      else
        Holding::ForwardCalculator.new(account)
      end
    end
end

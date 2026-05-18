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

    # Also remove non-provider rows on the provider's latest snapshot date for securities
    # that appear in the provider snapshot. The provider snapshot is authoritative for
    # those securities on that day, even when it is denominated in a different currency
    # than the account or the reverse-calculated holdings.
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
          # No new calculated value — fall back to the most recent provider
          # cost_basis for this security on or before the holding date.
          # Calculated/manual values outrank a provider carry-forward.
          existing_source = existing&.cost_basis_source
          preserve_existing = existing&.cost_basis.present? && %w[calculated manual].include?(existing_source)

          if preserve_existing
            holdings_to_upsert_without_cost << base_attrs
          else
            carried = carry_forward_provider_cost_basis(holding)

            if carried && (existing&.cost_basis != carried || existing_source != "provider")
              holdings_to_upsert_with_cost << base_attrs.merge(
                "cost_basis" => carried,
                "cost_basis_source" => "provider"
              )
            else
              # No cost_basis to set, or existing is better - don't touch cost_basis fields
              holdings_to_upsert_without_cost << base_attrs
            end
          end
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
      return if provider_security_ids.empty?

      deleted_count = account.holdings
        .where(account_provider_id: nil, date: provider_snapshot_date, security_id: provider_security_ids)
        .delete_all

      Rails.logger.info("Cleaned up #{deleted_count} stale calculated holdings on latest provider snapshot date") if deleted_count > 0
    end

    def holding_key(holding)
      [ holding.account_id || account.id, holding.security_id, holding.date, holding.currency ]
    end

    # Returns the most recent provider-supplied cost_basis for the given holding's
    # security on or before its date, converted to the holding's currency.
    # Used to backfill calculated rows past the provider's last snapshot so
    # reports keep showing trend data.
    #
    # Provider and calculated rows can be denominated in different currencies
    # (e.g., IBKR reports USD holdings while the reverse calculator converts to
    # the account's base currency). When they differ, the cost_basis is converted
    # at the snapshot date — the same convention ReverseCalculator uses for trade
    # prices — so the result is consistent with trade-derived cost_basis values.
    def carry_forward_provider_cost_basis(holding)
      snapshots = provider_cost_basis_snapshots[holding.security_id]
      return nil if snapshots.blank?

      result = nil
      snapshots.each do |snap_date, cost_basis, snap_currency|
        break if snap_date > holding.date
        result = [ cost_basis, snap_currency, snap_date ]
      end
      return nil unless result

      cost_basis, snap_currency, snap_date = result
      return cost_basis if snap_currency == holding.currency

      Money.new(cost_basis, snap_currency).exchange_to(holding.currency, date: snap_date).amount
    rescue Money::ConversionError
      nil
    end

    def provider_cost_basis_snapshots
      @provider_cost_basis_snapshots ||= begin
        ids = @holdings.map(&:security_id).uniq
        account.holdings
          .where.not(account_provider_id: nil)
          .where.not(cost_basis: nil)
          .where(security_id: ids)
          .order(:date) # ascending required: carry_forward_provider_cost_basis scans and breaks on snap_date > holding.date
          .pluck(:security_id, :currency, :date, :cost_basis)
          .each_with_object(Hash.new { |h, k| h[k] = [] }) do |(security_id, currency, date, cost_basis), memo|
            memo[security_id] << [ date, cost_basis, currency ]
          end
      end
    end

    def purge_stale_holdings
      portfolio_security_ids = account.trades.distinct.pluck(:security_id)

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

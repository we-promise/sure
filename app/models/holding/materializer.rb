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

      # Separate holdings into those with and without computed cost_basis
      holdings_with_cost_basis, holdings_without_cost_basis = @holdings.partition { |h| h.cost_basis.present? }

      # Upsert holdings that have computed cost_basis (from trades)
      # These will overwrite any existing provider cost_basis with the trade-derived value
      if holdings_with_cost_basis.any?
        account.holdings.upsert_all(
          holdings_with_cost_basis.map { |h|
            h.attributes
              .slice("date", "currency", "qty", "price", "amount", "security_id", "cost_basis")
              .merge("account_id" => account.id, "updated_at" => current_time)
          },
          unique_by: %i[account_id security_id date currency]
        )
      end

      # Upsert holdings WITHOUT cost_basis column - preserves existing provider cost_basis
      # This handles securities that have no trades (e.g., SimpleFIN-only holdings)
      if holdings_without_cost_basis.any?
        account.holdings.upsert_all(
          holdings_without_cost_basis.map { |h|
            h.attributes
              .slice("date", "currency", "qty", "price", "amount", "security_id")
              .merge("account_id" => account.id, "updated_at" => current_time)
          },
          unique_by: %i[account_id security_id date currency]
        )
      end
    end

    def purge_stale_holdings
      portfolio_security_ids = account.entries.trades.map { |entry| entry.entryable.security_id }.uniq

      # If there are no securities in the portfolio, delete all holdings
      if portfolio_security_ids.empty?
        Rails.logger.info("Clearing all holdings (no securities)")
        account.holdings.delete_all
      else
        deleted_count = account.holdings.delete_by("date < ? OR security_id NOT IN (?)", account.start_date, portfolio_security_ids)
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

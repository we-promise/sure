# Captures the most recent holding quantities for each security in an account's portfolio.
# Returns a portfolio hash compatible with the reverse calculator's format.
class Holding::PortfolioSnapshot
  attr_reader :account

  def initialize(account)
    @account = account
  end

  # Returns a hash of {security_id => qty} representing today's starting portfolio.
  # Includes all securities from trades (with 0 qty if no holdings exist).
  def to_h
    @portfolio ||= build_portfolio
  end

  private
    def build_portfolio
      # Start with all securities from trades initialized to 0
      portfolio = account.trades
        .pluck(:security_id)
        .uniq
        .each_with_object({}) { |security_id, hash| hash[security_id] = 0 }

      latest_holdings_scope.each do |holding|
        portfolio[holding.security_id] = holding.qty
      end

      portfolio
    end

    def latest_holdings_scope
      if (provider_snapshot_date = account.latest_provider_holdings_snapshot_date)
        account.holdings
          .where.not(account_provider_id: nil)
          .where(date: provider_snapshot_date)
      else
        account.holdings
          .select("DISTINCT ON (security_id) holdings.*")
          .order(:security_id, date: :desc)
      end
    end
end

class Holding::CurrentForInvestmentAccounts
  CURRENT_HOLDINGS_SQL = <<~SQL.squish.freeze
    (
      holdings.account_provider_id IS NOT NULL
      AND holdings.updated_at::date = (
        SELECT MAX(provider_holdings.updated_at::date)
        FROM holdings provider_holdings
        WHERE provider_holdings.account_id = holdings.account_id
          AND provider_holdings.account_provider_id IS NOT NULL
      )
    ) OR (
      NOT EXISTS (
        SELECT 1
        FROM holdings provider_holdings
        WHERE provider_holdings.account_id = holdings.account_id
          AND provider_holdings.account_provider_id IS NOT NULL
      )
      AND holdings.currency = (
        SELECT accounts.currency
        FROM accounts
        WHERE accounts.id = holdings.account_id
      )
      AND holdings.id = (
        SELECT latest_holdings.id
        FROM holdings latest_holdings
        WHERE latest_holdings.account_id = holdings.account_id
          AND latest_holdings.security_id = holdings.security_id
          AND latest_holdings.currency = holdings.currency
        ORDER BY latest_holdings.date DESC
        LIMIT 1
      )
    )
  SQL

  def initialize(account_ids)
    @account_ids = account_ids
  end

  def relation
    return Holding.none if account_ids.empty?

    Holding
      .where(account_id: account_ids)
      .where.not(qty: 0)
      .where(Arel.sql(CURRENT_HOLDINGS_SQL))
  end

  private
    attr_reader :account_ids
end

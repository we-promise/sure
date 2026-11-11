class Holding::CurrentForInvestmentAccounts
  # Each requested account's latest provider import day is computed once,
  # grouped by account, rather than as a subquery correlated to every row.
  # Correlated, it rescans the account's provider holdings per row, which is
  # quadratic in the number of provider rows an account keeps. The grouped
  # subquery is limited to the requested accounts so its cost follows them,
  # not the whole table. Accounts without provider holdings likewise take each
  # security's latest row in one DISTINCT ON pass, not one lookup per row.
  CURRENT_HOLDINGS_SQL = <<~SQL.squish.freeze
    (
      holdings.account_provider_id IS NOT NULL
      AND (holdings.account_id, holdings.updated_at::date) IN (
        SELECT provider_holdings.account_id, MAX(provider_holdings.updated_at::date)
        FROM holdings provider_holdings
        WHERE provider_holdings.account_id IN (:account_ids)
          AND provider_holdings.account_provider_id IS NOT NULL
        GROUP BY provider_holdings.account_id
      )
    ) OR holdings.id IN (
      SELECT DISTINCT ON (latest_holdings.account_id, latest_holdings.security_id) latest_holdings.id
      FROM holdings latest_holdings
      INNER JOIN accounts ON accounts.id = latest_holdings.account_id
      WHERE latest_holdings.account_id IN (:account_ids)
        AND accounts.id IN (:account_ids)
        AND latest_holdings.currency = accounts.currency
        AND latest_holdings.account_id NOT IN (
          SELECT provider_holdings.account_id
          FROM holdings provider_holdings
          WHERE provider_holdings.account_id IN (:account_ids)
            AND provider_holdings.account_provider_id IS NOT NULL
        )
      ORDER BY latest_holdings.account_id, latest_holdings.security_id, latest_holdings.date DESC
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
      .where(CURRENT_HOLDINGS_SQL, account_ids: account_ids)
  end

  private
    attr_reader :account_ids
end

module IncomeStatement::ClassificationSql
  SQL = <<~SQL.squish
    CASE
      WHEN %{transactions}.refund = true                                             THEN 'expense'
      WHEN %{transactions}.kind IN ('investment_contribution','loan_payment')         THEN 'expense'
      WHEN %{entries}.amount < 0                                                     THEN 'income'
      ELSE 'expense'
    END
  SQL

  def self.classification(transactions_alias: "at", entries_alias: "ae")
    SQL % { transactions: transactions_alias, entries: entries_alias }
  end

  def self.signed_amount(transactions_alias: "at", entries_alias: "ae")
    <<~SQL.squish
      CASE
        WHEN #{transactions_alias}.refund = true                                             THEN -ABS(#{entries_alias}.amount * COALESCE(er.rate, 1))
        WHEN #{transactions_alias}.kind IN ('investment_contribution','loan_payment')         THEN ABS(#{entries_alias}.amount * COALESCE(er.rate, 1))
        ELSE #{entries_alias}.amount * COALESCE(er.rate, 1)
      END
    SQL
  end
end

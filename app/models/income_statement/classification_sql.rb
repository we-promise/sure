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

  # Once signed_amount is SUM()'d for some grouping granularity (a period,
  # a category+period, etc.), refunds can make an 'expense' group's total go
  # negative (refunds > expenses) or an 'income' group's total go positive.
  # Wrapping the aggregate in ABS() at that point would report the group
  # under its *original* label with a magnitude that no longer reflects it
  # (e.g. a net-refund period showing up as "expense"). Instead, flip the
  # classification to match the sign of the net total, then ABS it — the
  # SQL-level equivalent of the flip IncomeStatement::Totals#call performs
  # in Ruby after its own query. Expects to run over an aggregated row that
  # exposes `classification_column` and `total_column`.
  def self.reclassify_by_sign(classification_column: "classification", total_column: "total")
    <<~SQL.squish
      CASE
        WHEN #{classification_column} = 'expense' AND #{total_column} < 0 THEN 'income'
        WHEN #{classification_column} = 'income'  AND #{total_column} > 0 THEN 'expense'
        ELSE #{classification_column}
      END
    SQL
  end
end

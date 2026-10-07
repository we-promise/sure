# Trade Republic syncs stored translated activity labels ("Storting",
# "Kaartbetaling", "Card payment") in whichever locale the sync job ran.
# Budgets, the import adapter and the label picker only know the fixed
# Transaction::ACTIVITY_LABELS values, so map each translation back to the
# value the importer now stores. Values outside that list are always from
# the importer: the label picker and Rules can only set listed values.
# English syncs stored listed values ("Withdrawal", "Contribution") that the
# importer no longer sets on non-investment accounts; those are cleared only
# when neither the user nor a Rule or other enrichment set the label.
class NormalizeTradeRepublicActivityLabels < ActiveRecord::Migration[8.1]
  LABEL_SCOPE = "trade_republic_items.activities.labels"

  # Label key => [label on an investment account, label on any other account]
  TARGETS = {
    "contribution" => [ "Contribution", nil ],
    "withdrawal" => [ "Withdrawal", nil ],
    "interest" => [ "Interest", "Interest" ],
    "dividend" => [ "Dividend", "Dividend" ],
    "card_fee" => [ "Fee", "Fee" ],
    "round_up" => [ "Buy", "Buy" ],
    "card_payment" => [ nil, nil ],
    "cash_withdrawal" => [ nil, nil ],
    "card_refund" => [ nil, nil ],
    "tax_refund" => [ nil, nil ]
  }.freeze

  def up
    TARGETS.each do |key, (investment_label, other_label)|
      clear_listed_labels(key, other_label)

      stale = translations_for(key) - Transaction::ACTIVITY_LABELS
      next if stale.empty?

      execute ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, { investment_label:, other_label:, stale: } ])
        UPDATE transactions
        SET investment_activity_label = CASE
          WHEN accounts.accountable_type = 'Investment' THEN CAST(:investment_label AS varchar)
          ELSE CAST(:other_label AS varchar)
        END
        FROM entries
        JOIN accounts ON accounts.id = entries.account_id
        WHERE entries.entryable_type = 'Transaction'
          AND entries.entryable_id = transactions.id
          AND entries.source = 'trade_republic'
          AND NOT (COALESCE(transactions.locked_attributes, '{}'::jsonb) ? 'investment_activity_label')
          AND transactions.investment_activity_label IN (:stale)
      SQL
    end
  end

  # The translated labels are not worth restoring.
  def down
  end

  private

    def clear_listed_labels(key, other_label)
      listed = translations_for(key) & Transaction::ACTIVITY_LABELS
      return if other_label || listed.empty?

      execute ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, { listed: } ])
        UPDATE transactions
        SET investment_activity_label = NULL
        FROM entries
        JOIN accounts ON accounts.id = entries.account_id
        WHERE entries.entryable_type = 'Transaction'
          AND entries.entryable_id = transactions.id
          AND entries.source = 'trade_republic'
          AND entries.user_modified = false
          AND accounts.accountable_type <> 'Investment'
          AND NOT (COALESCE(transactions.locked_attributes, '{}'::jsonb) ? 'investment_activity_label')
          AND transactions.investment_activity_label IN (:listed)
          AND NOT EXISTS (
            SELECT 1 FROM data_enrichments
            WHERE data_enrichments.enrichable_type = 'Transaction'
              AND data_enrichments.enrichable_id = transactions.id
              AND data_enrichments.attribute_name = 'investment_activity_label'
          )
      SQL
    end

    def translations_for(key)
      I18n.available_locales.filter_map { |locale| I18n.t(key, scope: LABEL_SCOPE, locale: locale, default: nil) }.uniq
    end
end

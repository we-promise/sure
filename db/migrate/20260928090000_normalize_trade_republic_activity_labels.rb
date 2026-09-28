# Trade Republic syncs stored translated activity labels ("Storting",
# "Kaartbetaling", "Card payment") in whichever locale the sync job ran.
# Budgets, the import adapter and the label picker only know the fixed
# Transaction::ACTIVITY_LABELS values, so map each translation back to the
# value the importer now stores. Only values outside that list are touched:
# the label picker and Rules can only set listed values, so an unlisted value
# on a Trade Republic row always came from the importer.
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
          AND transactions.investment_activity_label IN (:stale)
      SQL
    end
  end

  # The translated labels are not worth restoring.
  def down
  end

  private

    def translations_for(key)
      I18n.available_locales.filter_map { |locale| I18n.t(key, scope: LABEL_SCOPE, locale: locale, default: nil) }.uniq
    end
end

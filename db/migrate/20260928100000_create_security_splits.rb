class CreateSecuritySplits < ActiveRecord::Migration[8.1]
  def change
    # Stored per security, beside its prices, not per account: a split is a fact
    # about the instrument, and securities are shared across families (#249).
    create_table :security_splits, id: :uuid do |t|
      t.references :security, null: false, type: :uuid, foreign_key: { on_delete: :cascade }

      # The first trading day on the new share count. The holding calculators
      # apply the split at the open of this day, before its trades.
      t.date :ex_date, null: false

      # New shares per old: a 2-for-1 split is 2/1, a 1-for-10 reverse split
      # is 1/10. Kept as two integers so the ratio stays exact.
      t.integer :numerator, null: false
      t.integer :denominator, null: false

      t.string :source, null: false

      t.timestamps
    end

    add_index :security_splits, [ :security_id, :ex_date ], unique: true

    add_check_constraint :security_splits, "numerator > 0 AND denominator > 0", name: "security_splits_positive_terms"
    add_check_constraint :security_splits, "numerator <> denominator", name: "security_splits_not_one_to_one"
  end
end

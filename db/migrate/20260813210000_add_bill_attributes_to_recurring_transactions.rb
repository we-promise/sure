class AddBillAttributesToRecurringTransactions < ActiveRecord::Migration[7.2]
  def up
    change_table :recurring_transactions, bulk: true do |t|
      # Classification & linkage
      t.string :bill_type, null: false, default: "bill"
      t.references :category, type: :uuid, foreign_key: { on_delete: :nullify }, index: true
      t.uuid :replaced_by_id

      # Amount semantics
      t.string :amount_strategy, null: false, default: "fixed"
      t.decimal :amount_tolerance_pct, precision: 5, scale: 2, null: false, default: 7.5

      # Per-bill knobs (NULL = app default)
      t.integer :notify_days_before
      t.integer :upcoming_window_days
      t.integer :overdue_grace_days
      t.integer :match_days_early, null: false, default: 2
      t.integer :match_days_late, null: false, default: 7

      # Subscription lifecycle
      t.date :renews_on
      t.date :trial_ends_on
      t.date :cancelled_on

      # Matcher memory (transparent, user-visible)
      t.jsonb :matcher_hints, null: false, default: {}
    end

    add_foreign_key :recurring_transactions, :recurring_transactions,
                    column: :replaced_by_id, on_delete: :nullify

    # A transfer-shaped series is a payment obligation between two of the
    # user's own accounts (credit-card payment, loan payment); income is an
    # inflow (expenses are stored positive); everything else is a bill.
    execute <<~SQL
      UPDATE recurring_transactions
      SET bill_type = CASE
        WHEN destination_account_id IS NOT NULL THEN 'transfer'
        WHEN amount < 0 THEN 'income'
        ELSE 'bill'
      END
    SQL
  end

  def down
    remove_foreign_key :recurring_transactions, column: :replaced_by_id
    change_table :recurring_transactions, bulk: true do |t|
      t.remove :bill_type, :category_id, :replaced_by_id, :amount_strategy, :amount_tolerance_pct,
               :notify_days_before, :upcoming_window_days, :overdue_grace_days,
               :match_days_early, :match_days_late, :renews_on, :trial_ends_on, :cancelled_on,
               :matcher_hints
    end
  end
end

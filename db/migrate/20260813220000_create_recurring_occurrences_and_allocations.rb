class CreateRecurringOccurrencesAndAllocations < ActiveRecord::Migration[7.2]
  def change
    # One row per expected obligation instance. Materialized only inside a
    # rolling window or when carrying state; closed rows are immutable
    # history that survives any edit to the series definition.
    create_table :recurring_occurrences, id: :uuid do |t|
      t.references :recurring_transaction, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }, index: false
      t.references :family, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }, index: false
      t.date :original_due_on, null: false
      t.date :due_on, null: false
      t.string :currency, null: false
      t.decimal :expected_amount, precision: 19, scale: 4
      t.string :status, null: false, default: "scheduled"
      t.date :snoozed_until
      t.datetime :closed_at
      t.text :notes
      t.string :closed_source

      t.timestamps
    end

    add_index :recurring_occurrences, [ :recurring_transaction_id, :original_due_on ],
              unique: true, name: "idx_recurring_occurrences_identity"
    add_index :recurring_occurrences, [ :family_id, :status, :due_on ]
    add_index :recurring_occurrences, [ :family_id, :due_on ]
    add_check_constraint :recurring_occurrences,
                         "(status = 'scheduled') = (closed_at IS NULL)",
                         name: "chk_recurring_occurrences_closed_state"

    # Links payments to occurrences with an amount, which is what makes
    # partial payments first-class: several allocations sum toward one
    # obligation, and one entry can cover several. entry_id is nullable from
    # birth for payments recorded without a bank transaction, and nullified
    # on entry deletion so the payment record survives.
    create_table :recurring_allocations, id: :uuid do |t|
      t.references :recurring_occurrence, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }, index: false
      t.references :entry, type: :uuid, foreign_key: { on_delete: :nullify }, index: true
      t.decimal :allocated_amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.decimal :source_amount, precision: 19, scale: 4
      t.string :source_currency
      t.string :state, null: false, default: "confirmed"
      t.string :source, null: false
      t.decimal :match_confidence, precision: 5, scale: 4
      t.jsonb :match_signals, null: false, default: {}
      t.date :paid_on

      t.timestamps
    end

    add_index :recurring_allocations, [ :recurring_occurrence_id, :entry_id ],
              unique: true, where: "entry_id IS NOT NULL",
              name: "idx_recurring_allocations_entry_once"
    add_index :recurring_allocations, :recurring_occurrence_id
    add_check_constraint :recurring_allocations, "allocated_amount > 0",
                         name: "chk_recurring_allocations_amount_positive"

    # A rejected (series, entry) pair is never suggested again.
    create_table :recurring_match_rejections, id: :uuid do |t|
      t.references :recurring_transaction, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }, index: false
      t.references :entry, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }, index: false

      t.timestamps
    end

    add_index :recurring_match_rejections, [ :recurring_transaction_id, :entry_id ],
              unique: true, name: "idx_recurring_match_rejections_pair"

    # Price history per series, feeding subscription intelligence.
    create_table :recurring_price_changes, id: :uuid do |t|
      t.references :recurring_transaction, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }, index: false
      t.date :effective_on, null: false
      t.decimal :previous_amount, precision: 19, scale: 4, null: false
      t.decimal :new_amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.string :source, null: false
      t.references :entry, type: :uuid, foreign_key: { on_delete: :nullify }, index: false

      t.timestamps
    end

    add_index :recurring_price_changes, [ :recurring_transaction_id, :effective_on ],
              unique: true, name: "idx_recurring_price_changes_identity"
  end
end

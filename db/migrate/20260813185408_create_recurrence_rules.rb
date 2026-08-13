class CreateRecurrenceRules < ActiveRecord::Migration[7.2]
  def up
    create_table :recurrence_rules, id: :uuid do |t|
      t.references :recurring_transaction, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }, index: false
      t.string :frequency, null: false
      t.integer :interval, null: false, default: 1
      t.integer :day_of_month
      t.integer :weekday
      t.integer :weekday_ordinal
      t.integer :month_of_year
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    add_index :recurrence_rules, [ :recurring_transaction_id, :position ], unique: true

    add_check_constraint :recurrence_rules, "interval > 0", name: "chk_recurrence_rules_interval_positive"
    add_check_constraint :recurrence_rules,
      "day_of_month IS NULL OR (day_of_month BETWEEN -1 AND 31 AND day_of_month <> 0)",
      name: "chk_recurrence_rules_day_of_month_range"
    add_check_constraint :recurrence_rules, "weekday IS NULL OR weekday BETWEEN 0 AND 6",
      name: "chk_recurrence_rules_weekday_range"
    add_check_constraint :recurrence_rules,
      "weekday_ordinal IS NULL OR (weekday_ordinal BETWEEN -1 AND 5 AND weekday_ordinal <> 0)",
      name: "chk_recurrence_rules_weekday_ordinal_range"
    add_check_constraint :recurrence_rules, "month_of_year IS NULL OR month_of_year BETWEEN 1 AND 12",
      name: "chk_recurrence_rules_month_of_year_range"
    # An ordinal is meaningless without a weekday; a weekday without an ordinal
    # is legal only for weekly rules, which the model enforces (constraints
    # here stay shape-level so errors can carry messages).
    add_check_constraint :recurrence_rules,
      "weekday_ordinal IS NULL OR weekday IS NOT NULL",
      name: "chk_recurrence_rules_ordinal_requires_weekday"
    add_check_constraint :recurrence_rules,
      "NOT (day_of_month IS NOT NULL AND weekday IS NOT NULL)",
      name: "chk_recurrence_rules_single_day_spec"

    change_table :recurring_transactions, bulk: true do |t|
      t.date :anchor_date
      t.string :end_mode, null: false, default: "never"
      t.date :end_on
      t.integer :end_after_count
      t.string :weekend_adjust, null: false, default: "none"
      t.string :holiday_calendar
    end

    # Every existing series is monthly on expected_day_of_month; give each an
    # explicit rule saying exactly that, anchored on its last occurrence. A
    # series with zero rules stays legal (Schedule synthesizes the implicit
    # monthly rule), so this backfill is a normalization, not a requirement.
    execute <<~SQL
      INSERT INTO recurrence_rules (id, recurring_transaction_id, frequency, interval, day_of_month, position, created_at, updated_at)
      SELECT gen_random_uuid(), id, 'monthly', 1, expected_day_of_month, 0, NOW(), NOW()
      FROM recurring_transactions
    SQL

    execute <<~SQL
      UPDATE recurring_transactions SET anchor_date = last_occurrence_date WHERE anchor_date IS NULL
    SQL
  end

  def down
    change_table :recurring_transactions, bulk: true do |t|
      t.remove :anchor_date, :end_mode, :end_on, :end_after_count, :weekend_adjust, :holiday_calendar
    end
    drop_table :recurrence_rules
  end
end

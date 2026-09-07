class CreateLoanScenarios < ActiveRecord::Migration[7.2]
  def change
    create_table :loan_scenarios, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :loan, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      # Attribution and display only, NEVER access control. A scenario is a
      # shared household artifact: anyone who can see the loan can edit or
      # delete it, and this column exists so the UI can say whose it was.
      t.references :created_by_user, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }

      t.string :name, null: false, limit: 100
      t.string :currency, null: false
      t.decimal :assumed_offset_balance, precision: 19, scale: 4
      t.decimal :rate_override, precision: 10, scale: 3

      # F8: the cap of five is STRUCTURAL, not a validation. A `position < 5`
      # row check never bounded the row count -- five rows can all hold
      # position 0 -- and counting in the model races under concurrent
      # creation. An allocated slot with a unique index is true under
      # concurrency because the database enforces it.
      t.integer :slot, null: false

      # F7: reproducibility. The simulation RESULT is deliberately not stored
      # (a stale persisted figure is a support liability, not an optimisation),
      # but support needs to know which engine produced a number a user is
      # quoting.
      t.integer :calculator_version, null: false
      t.datetime :last_calculated_at

      t.timestamps
    end

    add_index :loan_scenarios, [ :loan_id, :slot ], unique: true

    # NO unique index on (loan_id, name). Accounts are shared per user through
    # `account_shares`, so two household members can both see one loan; a
    # unique name index would turn a cosmetic collision between housemates
    # into an error.

    add_check_constraint :loan_scenarios, "slot >= 0 AND slot <= 4",
      name: "chk_loan_scenarios_slot_range"
    add_check_constraint :loan_scenarios,
      "rate_override IS NULL OR (rate_override >= 0 AND rate_override <= 100)",
      name: "chk_loan_scenarios_rate_override_range"
    add_check_constraint :loan_scenarios,
      "assumed_offset_balance IS NULL OR assumed_offset_balance >= 0",
      name: "chk_loan_scenarios_offset_non_negative"
  end
end

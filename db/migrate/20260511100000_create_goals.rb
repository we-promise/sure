class CreateGoals < ActiveRecord::Migration[7.2]
  def change
    create_enum :goal_pledge_kind, %w[transfer manual_save]
    create_enum :goal_pledge_status, %w[open matched cancelled expired]

    create_table :goals, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :name, null: false
      t.decimal :target_amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.date :target_date
      t.string :color
      t.text :notes
      t.string :state, null: false, default: "active"

      t.timestamps

      t.string :icon
    end

    add_index :goals, [ :family_id, :state ]
    add_check_constraint :goals, "char_length(name) <= 255", name: "chk_savings_goals_name_length"
    add_check_constraint :goals, "target_amount > 0", name: "chk_savings_goals_target_amount_positive"
    add_check_constraint :goals,
                         "state IN ('active','paused','completed','archived')",
                         name: "chk_savings_goals_state_enum"

    create_table :goal_accounts, id: :uuid do |t|
      t.references :goal, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :account, null: false, foreign_key: { on_delete: :restrict }, type: :uuid

      t.timestamps
    end

    add_index :goal_accounts, [ :goal_id, :account_id ],
              unique: true,
              name: "index_savings_goal_accounts_on_goal_and_account"

    create_table :goal_pledges, id: :uuid do |t|
      t.references :goal, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :account, null: false, foreign_key: { on_delete: :restrict }, type: :uuid
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.enum :kind, enum_type: :goal_pledge_kind, null: false
      t.enum :status, enum_type: :goal_pledge_status, null: false, default: "open"
      t.datetime :expires_at, null: false
      t.uuid :matched_transaction_id

      t.timestamps
    end

    add_foreign_key :goal_pledges, :transactions, column: :matched_transaction_id, on_delete: :nullify

    add_index :goal_pledges, [ :goal_id, :status ]
    add_index :goal_pledges, [ :status, :expires_at ],
              where: "status = 'open'",
              name: "index_goal_pledges_open_by_expiry"
    add_index :goal_pledges, :matched_transaction_id,
              unique: true,
              where: "matched_transaction_id IS NOT NULL"

    add_check_constraint :goal_pledges, "amount > 0", name: "chk_goal_pledges_amount_positive"
  end
end

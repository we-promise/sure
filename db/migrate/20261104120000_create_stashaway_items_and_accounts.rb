class CreateStashawayItemsAndAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :stashaway_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :status, default: "good", null: false
      t.boolean :scheduled_for_deletion, default: false, null: false
      t.boolean :pending_account_setup, default: false, null: false
      t.string :region, default: "sg", null: false
      t.string :email
      t.string :device_id, null: false
      t.string :stashaway_user_id
      t.text :api_token
      t.text :password
      t.text :pending_login_token
      t.datetime :pending_login_started_at

      t.timestamps
    end

    add_index :stashaway_items, :status

    create_table :stashaway_accounts, id: :uuid do |t|
      t.references :stashaway_item, null: false, foreign_key: true, type: :uuid
      t.string :group_key, null: false
      t.string :name
      t.string :goal_type
      t.string :funding_source
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.date :last_nav_date
      t.date :import_start_date
      t.decimal :import_base, precision: 19, scale: 4
      t.jsonb :raw_goals_payload, default: [], null: false
      t.string :goal_ids, array: true, default: [], null: false

      t.timestamps
    end
  end
end

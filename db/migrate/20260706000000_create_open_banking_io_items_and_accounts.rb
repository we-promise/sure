class CreateOpenBankingIoItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :open_banking_io_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :institution_id
      t.string :institution_name
      t.string :institution_domain
      t.string :institution_url
      t.string :institution_color
      t.string :status, default: "good", null: false
      t.boolean :scheduled_for_deletion, default: false, null: false
      t.boolean :pending_account_setup, default: false, null: false
      t.date :sync_start_date
      t.jsonb :raw_payload
      t.jsonb :raw_institution_payload
      t.text :api_base_url
      t.text :api_key
      t.text :private_key
      t.timestamps
    end

    add_index :open_banking_io_items, :status

    create_table :open_banking_io_accounts, id: :uuid do |t|
      t.references :open_banking_io_item, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :account_id
      t.string :formatted_account
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :available_balance, precision: 19, scale: 4
      t.decimal :balance_limit, precision: 19, scale: 4
      t.string :account_status
      t.string :account_type
      t.string :provider
      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload
      t.date :sync_start_date

      t.timestamps
    end

    add_index :open_banking_io_accounts, :account_id
    add_index :open_banking_io_accounts,
              [ :open_banking_io_item_id, :account_id ],
              unique: true,
              where: "account_id IS NOT NULL",
              name: "index_open_banking_io_accounts_on_item_and_account_id"
  end
end

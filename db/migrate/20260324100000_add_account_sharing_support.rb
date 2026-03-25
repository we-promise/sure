class AddAccountSharingSupport < ActiveRecord::Migration[7.2]
  def change
    # Family-level default: whether new accounts are shared with all members by default
    add_column :families, :default_account_sharing, :string, default: "shared", null: false

    # Account ownership: who created/owns the account
    add_reference :accounts, :owner, type: :uuid, foreign_key: { to_table: :users }, null: true, index: true

    # Sharing join table: per-user access to accounts they don't own
    create_table :account_shares, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :account, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.string :permission, null: false, default: "read_only"
      t.boolean :include_in_finances, null: false, default: true
      t.timestamps
    end

    add_index :account_shares, [ :account_id, :user_id ], unique: true
    add_index :account_shares, [ :user_id, :include_in_finances ]
  end
end

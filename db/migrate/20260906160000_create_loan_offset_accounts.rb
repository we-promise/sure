class CreateLoanOffsetAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :loan_offset_accounts, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :loan, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :account, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.timestamps
    end

    add_index :loan_offset_accounts, [ :loan_id, :account_id ], unique: true
  end
end

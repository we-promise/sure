class CreateTransactionExclusions < ActiveRecord::Migration[7.1]
  def change
    create_table :transaction_exclusions do |t|
      t.uuid :family_id, null: false
      t.string :external_id, null: false
      t.string :provider, null: false
      t.string :exclusion_reason, null: false
      t.timestamps
    end

    add_foreign_key :transaction_exclusions, :families, column: :family_id
    add_index :transaction_exclusions, [ :family_id, :external_id, :provider ], unique: true, name: "index_transaction_exclusions_unique"
    add_index :transaction_exclusions, [ :family_id, :provider, :exclusion_reason ]
  end
end

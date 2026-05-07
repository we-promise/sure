class ChangeTransactionExclusionsToUuid < ActiveRecord::Migration[7.1]
  def up
    # Recreate transaction_exclusions with UUID primary key to match app conventions.
    # Safe to drop and recreate: table is append-only and only populated during merges,
    # so any existing rows can be rebuilt organically on next merge/sync.
    drop_table :transaction_exclusions

    create_table :transaction_exclusions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
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

  def down
    drop_table :transaction_exclusions

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

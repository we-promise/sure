class CreateAccountProviders < ActiveRecord::Migration[7.2]
  def change
    create_table :account_providers, id: :uuid do |t|
      t.references :account, type: :uuid, null: false, foreign_key: true, index: true
      t.references :provider, type: :uuid, null: false, polymorphic: true, index: true
      t.timestamps
    end

    # Ensure an account can only have one provider of each type
    add_index :account_providers, [ :account_id, :provider_type ], unique: true

    # Ensure a provider can only be linked to one account
    add_index :account_providers, [ :provider_type, :provider_id ], unique: true
  end
end

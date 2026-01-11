class CreateSsoProviders < ActiveRecord::Migration[7.2]
  def change
    create_table :sso_providers, id: :uuid do |t|
      t.string :strategy, null: false
      t.string :name, null: false
      t.string :label, null: false
      t.string :icon
      t.boolean :enabled, null: false, default: true
      t.string :issuer
      t.string :client_id
      t.string :client_secret
      t.string :redirect_uri
      t.jsonb :settings, null: false, default: {}

      t.timestamps
    end

    add_index :sso_providers, :name, unique: true
    add_index :sso_providers, :enabled
  end
end

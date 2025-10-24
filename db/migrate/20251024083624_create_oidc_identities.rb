class CreateOidcIdentities < ActiveRecord::Migration[7.2]
  def change
    create_table :oidc_identities, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :provider, null: false
      t.string :uid, null: false
      t.jsonb :info, default: {}
      t.datetime :last_authenticated_at

      t.timestamps
    end

    add_index :oidc_identities, [ :provider, :uid ], unique: true
  end
end

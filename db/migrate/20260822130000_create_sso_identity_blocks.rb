class CreateSsoIdentityBlocks < ActiveRecord::Migration[7.2]
  def change
    create_table :sso_identity_blocks, id: :uuid do |t|
      t.string :provider, null: false
      t.string :uid_digest, null: false
      t.text :identity_label, null: false

      t.timestamps
    end

    add_index :sso_identity_blocks, [ :provider, :uid_digest ], unique: true
  end
end

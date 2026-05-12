class CreateWebauthnCredentials < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :webauthn_id, :string
    add_index :users, :webauthn_id, unique: true, where: "webauthn_id IS NOT NULL"

    create_table :webauthn_credentials, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :nickname, null: false
      t.string :credential_id, null: false
      t.text :public_key, null: false
      t.bigint :sign_count, null: false, default: 0
      t.string :transports, array: true, null: false, default: []
      t.datetime :last_used_at

      t.timestamps
    end

    add_index :webauthn_credentials, :credential_id, unique: true
    add_check_constraint :webauthn_credentials, "sign_count >= 0", name: "chk_webauthn_credentials_sign_count_non_negative"
  end
end

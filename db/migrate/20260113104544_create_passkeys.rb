class CreatePasskeys < ActiveRecord::Migration[7.2]
  def change
    create_table :passkeys, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :external_id, null: false
      t.string :public_key, null: false
      t.string :label
      t.bigint :sign_count, default: 0, null: false
      t.datetime :last_used_at

      t.timestamps
    end

    add_index :passkeys, :external_id, unique: true
  end
end

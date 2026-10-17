class CreateFinecoItems < ActiveRecord::Migration[8.1]
  def change
    create_table :fineco_items, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :owner, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.text :gsessionid, null: false
      t.text :account_index, null: false
      t.text :dossier_index, null: false
      t.datetime :captured_at, null: false

      t.timestamps
    end

    add_index :fineco_items, [ :family_id, :owner_id ], unique: true
  end
end

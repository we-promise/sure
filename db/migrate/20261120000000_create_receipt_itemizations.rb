class CreateReceiptItemizations < ActiveRecord::Migration[8.1]
  def change
    create_table :receipt_itemizations, id: :uuid do |t|
      t.references :transaction, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :attachment, type: :uuid, null: false, foreign_key: { to_table: :active_storage_attachments, on_delete: :cascade }
      t.string :status, null: false, default: "pending"
      t.jsonb :proposal, null: false, default: {}
      t.string :error_code
      t.timestamps
    end
  end
end

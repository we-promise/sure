class CreateReceiptScans < ActiveRecord::Migration[8.1]
  def change
    create_table :receipt_scans, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :account, null: false, foreign_key: true, type: :uuid
      t.references :user, foreign_key: { on_delete: :nullify }, type: :uuid
      t.references :transaction, foreign_key: { on_delete: :nullify }, type: :uuid
      t.string :status, null: false, default: "processing"
      t.jsonb :extraction, null: false, default: {}
      t.jsonb :review_reasons, null: false, default: []
      t.text :error

      t.timestamps
    end

    add_index :receipt_scans, %i[family_id created_at]
  end
end

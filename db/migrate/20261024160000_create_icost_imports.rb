class CreateIcostImports < ActiveRecord::Migration[8.1]
  def change
    create_table :icost_imports, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.string :filename, null: false
      t.string :file_sha256, null: false
      t.string :sheet_name, null: false
      t.jsonb :headers, null: false, default: []
      t.binary :source_bytes, null: false
      t.timestamps
    end
    add_index :icost_imports, [ :user_id, :file_sha256 ], unique: true

    create_table :icost_records, id: :uuid do |t|
      t.references :icost_import, type: :uuid, null: false, foreign_key: true
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.references :entry, type: :uuid, foreign_key: { on_delete: :nullify }, index: { unique: true }
      t.references :counterpart_entry, type: :uuid, foreign_key: { to_table: :entries, on_delete: :nullify }, index: { unique: true }
      t.integer :source_row, null: false
      t.string :source_id, null: false
      t.string :row_sha256, null: false
      t.string :status, null: false, default: "needs_review"
      t.jsonb :source_values, null: false, default: []
      t.jsonb :raw_fields, null: false, default: {}
      t.jsonb :unknown_fields, null: false, default: {}
      t.jsonb :issues, null: false, default: []
      t.jsonb :resolution, null: false, default: {}
      t.text :review_note
      t.string :recorded_at_text
      t.string :transaction_type
      t.decimal :amount
      t.string :currency
      t.jsonb :category_path, null: false, default: []
      t.string :account_name
      t.string :counterparty_name
      t.string :book_name
      t.text :note
      t.jsonb :tags, null: false, default: []
      t.text :location_text
      t.decimal :latitude
      t.decimal :longitude
      t.string :coordinate_system, null: false, default: "unknown"
      t.decimal :refund_amount
      t.decimal :discount_amount
      t.decimal :fee_amount
      t.jsonb :image_references, null: false, default: {}
      t.timestamps
    end
    add_index :icost_records, [ :family_id, :source_id ], unique: true
    add_index :icost_records, [ :family_id, :row_sha256 ]
    add_index :icost_records, [ :icost_import_id, :status ]
    add_check_constraint :icost_records, "status IN ('ready', 'needs_review', 'published')", name: "icost_records_status"
  end
end

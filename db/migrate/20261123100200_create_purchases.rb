class CreatePurchases < ActiveRecord::Migration[8.1]
  def change
    create_table :purchases, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.references :transaction, null: true, foreign_key: { on_delete: :nullify }, type: :uuid, index: { unique: true }
      t.references :receipt_scan, null: true, foreign_key: { on_delete: :nullify }, type: :uuid, index: { unique: true }
      t.string :inbound_email_message_id
      t.string :source, null: false
      t.string :status, null: false, default: "processing"
      t.string :merchant
      t.string :order_number
      t.date :ordered_on
      t.decimal :total, precision: 19, scale: 4
      t.string :currency
      t.decimal :shipping_cost, precision: 19, scale: 4
      t.string :payment_method, null: false, default: "unknown"
      t.uuid :match_candidate_entry_ids, array: true, null: false, default: []
      t.uuid :rejected_entry_ids, array: true, null: false, default: []
      t.datetime :matched_at
      t.date :match_deadline_on
      t.datetime :unmatched_notified_at
      t.jsonb :review_reasons, null: false, default: []
      t.jsonb :ai_metadata, null: false, default: {}
      t.text :error
      t.timestamps
    end

    add_index :purchases, [ :family_id, :status ]
    add_index :purchases, [ :family_id, :ordered_on ]
    add_index :purchases, "family_id, lower(merchant), lower(order_number)", name: "index_purchases_on_family_merchant_order_number"

    create_table :purchase_items, id: :uuid do |t|
      t.references :purchase, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: false
      t.references :category, null: true, foreign_key: { on_delete: :nullify }, type: :uuid
      t.string :name, null: false
      t.decimal :quantity, precision: 19, scale: 4
      t.decimal :unit_price, precision: 19, scale: 4
      t.decimal :amount, precision: 19, scale: 4
      t.string :seller
      t.integer :position, null: false, default: 0
      t.timestamps
    end

    add_index :purchase_items, [ :purchase_id, :position ]

    create_table :purchase_inbox_routes, id: :uuid do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :kind, null: false
      t.string :value, null: false
      t.timestamps
    end

    add_index :purchase_inbox_routes, "kind, lower(value)", unique: true, name: "index_purchase_inbox_routes_on_kind_and_value"
  end
end

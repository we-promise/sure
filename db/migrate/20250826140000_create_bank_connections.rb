class CreateBankConnections < ActiveRecord::Migration[7.2]
  def change
    create_table :bank_connections, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :name, null: false
      t.text :credentials
      t.string :status, default: "good"
      t.boolean :scheduled_for_deletion, default: false
      t.boolean :pending_account_setup, default: false, null: false
      t.jsonb :raw_payload

      t.timestamps
    end

    add_index :bank_connections, :provider
    add_index :bank_connections, :status
  end
end

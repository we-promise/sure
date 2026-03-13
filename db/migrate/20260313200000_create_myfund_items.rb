class CreateMyfundItems < ActiveRecord::Migration[7.2]
  def change
    create_table :myfund_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false, default: "myFund.pl"
      t.string :api_key, null: false
      t.string :portfolio_name, null: false
      t.string :status, null: false, default: "good"
      t.datetime :last_synced_at
      t.boolean :scheduled_for_deletion, default: false, null: false
      t.text :raw_payload

      t.timestamps
    end

    add_index :myfund_items, :family_id
  end
end

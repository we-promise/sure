class CreateSimplefinItems < ActiveRecord::Migration[7.2]
  def change
    create_table :simplefin_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.text :access_url
      t.string :name
      t.string :institution_id
      t.string :institution_name
      t.string :institution_url
      t.string :status, default: "good"
      t.boolean :scheduled_for_deletion, default: false

      t.index :status
      t.jsonb :raw_payload
      t.jsonb :raw_institution_payload

      t.timestamps
    end
  end
end

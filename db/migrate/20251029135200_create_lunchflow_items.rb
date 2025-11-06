class CreateLunchflowItems < ActiveRecord::Migration[7.2]
  def change
    create_table :lunchflow_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :institution_id
      t.string :institution_name
      t.string :institution_domain
      t.string :institution_url
      t.string :institution_color
      t.string :status, default: "good"
      t.boolean :scheduled_for_deletion, default: false
      t.boolean :pending_account_setup, default: false
      t.datetime :sync_start_date

      t.index :status
      t.jsonb :raw_payload
      t.jsonb :raw_institution_payload

      t.timestamps
    end
  end
end

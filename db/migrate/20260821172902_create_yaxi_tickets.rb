class CreateYaxiTickets < ActiveRecord::Migration[8.1]
  def change
    create_table :yaxi_tickets, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :service, null: false
      t.jsonb :service_data
      t.datetime :expires_at, null: false
      t.datetime :consumed_at

      t.timestamps
    end

    add_index :yaxi_tickets, :expires_at
    add_index :yaxi_tickets,
              [ :family_id, :user_id, :consumed_at ],
              name: "index_yaxi_tickets_on_owner_and_consumed"
  end
end

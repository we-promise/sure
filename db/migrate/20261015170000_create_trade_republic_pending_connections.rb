class CreateTradeRepublicPendingConnections < ActiveRecord::Migration[8.1]
  def change
    # A new connection's login until Trade Republic approves it; only then is
    # a trade_republic_items row created.
    create_table :trade_republic_pending_connections, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :phone_number
      t.text :pending_login_state
      t.string :currency
      t.uuid :device_id, default: -> { "gen_random_uuid()" }, null: false
      t.timestamps
    end
  end
end

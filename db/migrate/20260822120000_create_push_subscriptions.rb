class CreatePushSubscriptions < ActiveRecord::Migration[8.0]
  def change
    create_table :push_subscriptions, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :token, null: false
      t.string :environment, null: false
      t.string :platform, null: false, default: "ios"
      t.datetime :last_registered_at, null: false

      t.timestamps
    end

    add_index :push_subscriptions, :token, unique: true
    add_index :push_subscriptions, :last_registered_at
  end
end

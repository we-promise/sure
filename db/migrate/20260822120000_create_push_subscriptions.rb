class CreatePushSubscriptions < ActiveRecord::Migration[7.2]
  def change
    create_table :push_subscriptions, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :token, null: false
      t.string :environment, null: false
      t.string :platform, null: false, default: "ios"
      t.datetime :last_registered_at, null: false

      t.timestamps
    end

    add_index :push_subscriptions, "lower(token)",
              unique: true,
              name: "index_push_subscriptions_on_lower_token"
    add_index :push_subscriptions, :last_registered_at
    add_check_constraint :push_subscriptions,
                         "environment IN ('sandbox', 'production')",
                         name: "chk_push_subscriptions_environment"
    add_check_constraint :push_subscriptions,
                         "platform = 'ios'",
                         name: "chk_push_subscriptions_platform"
  end
end

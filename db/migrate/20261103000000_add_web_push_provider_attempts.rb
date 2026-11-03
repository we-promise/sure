class AddWebPushProviderAttempts < ActiveRecord::Migration[8.1]
  def change
    add_column :web_push_deliveries, :provider_attempts, :integer, default: 0, null: false
    add_column :web_push_deliveries, :attempted_at, :datetime
    add_check_constraint :web_push_deliveries, "provider_attempts >= 0",
      name: "chk_web_push_deliveries_provider_attempts"
  end
end

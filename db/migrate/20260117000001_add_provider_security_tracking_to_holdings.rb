class AddProviderSecurityTrackingToHoldings < ActiveRecord::Migration[7.2]
  def change
    add_reference :holdings, :provider_security, type: :uuid, null: true, foreign_key: { to_table: :securities }
    add_column :holdings, :security_locked, :boolean, default: false, null: false
  end
end

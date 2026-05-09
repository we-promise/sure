class ChangeProviderConnectionStatusDefault < ActiveRecord::Migration[7.2]
  def up
    change_column_default :provider_connections, :status, from: "pending", to: "healthy"
  end

  def down
    change_column_default :provider_connections, :status, from: "healthy", to: "pending"
  end
end

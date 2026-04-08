class AddOfflineReasonToSecurities < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    add_column :securities, :offline_reason, :string
    add_index :securities, [:price_provider, :offline_reason], algorithm: :concurrently
  end
end

class AddOfflineReasonToSecurities < ActiveRecord::Migration[7.2]
  def change
    add_column :securities, :offline_reason, :string
  end
end

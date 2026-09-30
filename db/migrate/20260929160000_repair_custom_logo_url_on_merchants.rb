class RepairCustomLogoUrlOnMerchants < ActiveRecord::Migration[8.1]
  def up
    add_column :merchants, :custom_logo_url, :string unless column_exists?(:merchants, :custom_logo_url)
  end

  def down
    # The preceding migration owns this column, including on clean databases.
  end
end

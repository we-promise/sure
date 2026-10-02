class AddCustomLogoUrlToMerchants < ActiveRecord::Migration[8.1]
  def change
    add_column :merchants, :custom_logo_url, :string
  end
end

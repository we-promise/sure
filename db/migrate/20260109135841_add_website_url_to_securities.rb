class AddWebsiteUrlToSecurities < ActiveRecord::Migration[7.2]
  def change
    add_column :securities, :website_url, :string
  end
end

class AddMerchantDomainToPurchases < ActiveRecord::Migration[8.1]
  def change
    add_column :purchases, :merchant_domain, :string
  end
end

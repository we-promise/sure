class AddProviderMerchantIdIndexToMerchants < ActiveRecord::Migration[7.2]
  def change
    # Add unique index on provider_merchant_id + source for ProviderMerchant
    add_index :merchants, [ :provider_merchant_id, :source ],
              unique: true,
              where: "provider_merchant_id IS NOT NULL AND type = 'ProviderMerchant'",
              name: "index_merchants_on_provider_merchant_id_and_source"
  end
end

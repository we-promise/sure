class AddSochainApiKeyToOnchainWalletItems < ActiveRecord::Migration[8.1]
  def change
    add_column :onchain_wallet_items, :sochain_api_key, :text
  end
end

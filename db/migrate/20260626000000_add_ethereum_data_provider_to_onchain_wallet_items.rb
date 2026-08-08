# frozen_string_literal: true

class AddEthereumDataProviderToOnchainWalletItems < ActiveRecord::Migration[7.2]
  def change
    add_column :onchain_wallet_items, :ethereum_data_provider, :string, null: false, default: "blockscout"
  end
end

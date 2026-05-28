# frozen_string_literal: true

module OnchainWalletItem::Provided
  extend ActiveSupport::Concern

  def mempool_space_provider
    Provider::MempoolSpace.new
  end

  def etherscan_provider
    return nil unless credentials_configured?

    Provider::Etherscan.new(api_key: etherscan_api_key)
  end
end

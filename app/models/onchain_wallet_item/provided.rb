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

  # Keyless EVM provider used for Ethereum and all other supported EVM chains.
  # @param chain [String] e.g. "ethereum", "polygon", "arbitrum"
  def blockscout_provider(chain)
    Provider::Blockscout.new(chain: chain)
  end

  # Keyless Solana provider (public RPC).
  def solana_provider
    Provider::SolanaRpc.new
  end
end

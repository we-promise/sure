# frozen_string_literal: true

# Connects the item to the chain adapters, injecting the family's optional
# explorer credential. Adapters are resolved through Onchain::Chains so this
# concern never learns a chain name.
module OnchainWalletItem::Provided
  extend ActiveSupport::Concern

  def chain_adapter(chain)
    Onchain::Chains.adapter_for(chain, credentials: onchain_credentials)
  end

  # Chains whose address format matches, paired with their adapter. Used by the
  # linking flow to work out which chain(s) an address could belong to.
  def matching_chain_adapters(address)
    Onchain::Chains.matching(address).map do |definition|
      [ definition, definition.adapter(credentials: onchain_credentials) ]
    end
  end

  def onchain_credentials
    { etherscan_api_key: etherscan_api_key.presence }
  end
end

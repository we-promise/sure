# frozen_string_literal: true

# The contract every chain implementation fulfils. An adapter is the only
# place in the codebase allowed to know how a specific chain works; it turns
# that knowledge into an Onchain::Snapshot and nothing else.
module Onchain::ChainAdapter
  # @param address [String]
  # @return [Boolean] whether the address is well-formed for this chain.
  #   Must never make a network call.
  def valid_address?(_address)
    raise NotImplementedError, "#{self.class} must implement #valid_address?"
  end

  # @param address [String]
  # @return [Onchain::Snapshot]
  def fetch_snapshot(_address)
    raise NotImplementedError, "#{self.class} must implement #fetch_snapshot"
  end

  # Whether this address is worth tracking on this chain, answered with at most
  # ONE bounded request and never by reading paginated history. Only chains that
  # share an address format with other chains (every EVM network) need to
  # override this; elsewhere a well-formed address is answer enough.
  def has_activity?(address)
    valid_address?(address)
  end
end

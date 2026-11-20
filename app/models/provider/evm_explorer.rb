# frozen_string_literal: true

# The contract an EVM data source fulfils, so Onchain::EvmAdapter can use a
# keyless public indexer or a keyed one without changing.
#
# Amounts are returned in each token's smallest unit ("raw"), as strings or
# integers, because that is what every explorer reports and the only lossless
# form; the adapter scales them by the token's decimals.
module Provider::EvmExplorer
  # Whether this address is worth tracking on this chain.
  #
  # MUST cost at most one request and MUST NOT read paginated transfer history:
  # this is called once per candidate network every time someone pastes a 0x
  # address, so a history walk here would turn linking into dozens of requests.
  # @return [Boolean]
  def has_activity?(_address)
    raise NotImplementedError, "#{self.class} must implement #has_activity?"
  end

  # @return [String, Integer] native coin balance in wei
  def native_balance(_address)
    raise NotImplementedError, "#{self.class} must implement #native_balance"
  end

  # @return [Array<Hash>] { contract:, symbol:, name:, decimals:, raw_amount: }
  def token_balances(_address)
    raise NotImplementedError, "#{self.class} must implement #token_balances"
  end

  # Signed transfers, native and ERC-20 together. Positive raw_amount means the
  # address received; negative means it sent. `contract` is nil for the native
  # coin.
  # @return [Array<Hash>] { external_id:, contract:, symbol:, decimals:, raw_amount:, timestamp: }
  def transfers(_address)
    raise NotImplementedError, "#{self.class} must implement #transfers"
  end
end

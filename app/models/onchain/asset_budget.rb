# frozen_string_literal: true

# How many tokens one address may surface in a single read.
#
# Real addresses are airdrop dumping grounds: a well-known Ethereum address
# holds nearly 8,000 ERC-20 tokens, and a comparable Solana one nearly 3,000
# token accounts. Unbounded, that means a review screen with thousands of rows
# nobody can use, and — on Solana, where names are looked up in batches — dozens
# of extra requests per sync.
#
# The bound is on what is *surfaced*, not on what is held: the native asset is
# never affected, and anything already tracked keeps syncing.
module Onchain
  module AssetBudget
    DEFAULT_TOKENS = 200
    MAX_TOKENS = 5_000

    class << self
      def tokens
        configured = ENV["ONCHAIN_MAX_TOKENS_PER_ADDRESS"].to_i
        return DEFAULT_TOKENS unless configured.positive?

        configured.clamp(1, MAX_TOKENS)
      end
    end
  end
end

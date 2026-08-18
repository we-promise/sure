# frozen_string_literal: true

# How deep a single sync reads an address's transfer history.
#
# Every source is a free, shared endpoint that throttles, so history has to be
# bounded — but the bound is a hosting decision, not a property of a chain. A
# self-hoster with their own node or indexer can raise it; the default keeps a
# public endpoint usable.
#
# Balances never depend on this: they come from a summary, not from history.
module Onchain
  module HistoryBudget
    DEFAULT_PAGES = 10
    # Rows per page on the paginated sources, and the factor that turns the page
    # budget into Solana's per-transaction budget (there, one transaction is one
    # RPC call).
    PAGE_SIZE = 25
    MAX_PAGES = 200

    class << self
      def pages
        configured = ENV["ONCHAIN_HISTORY_MAX_PAGES"].to_i
        return DEFAULT_PAGES unless configured.positive?

        configured.clamp(1, MAX_PAGES)
      end

      def transactions
        pages * PAGE_SIZE
      end
    end
  end
end

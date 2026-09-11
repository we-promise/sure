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
    PAGE_SIZE = 25
    MAX_PAGES = 200

    # Sources that answer one transaction per request (Solana's getTransaction)
    # get their own, much smaller budget: reading a page of 25 costs one request
    # on Bitcoin and 25 on Solana, so the same nominal depth is an order of
    # magnitude more expensive there. Scaled off the page budget so one knob
    # still moves both, anchored on defaults that a public endpoint can serve.
    DEFAULT_TRANSACTIONS = 25

    class << self
      def pages
        configured = ENV["ONCHAIN_HISTORY_MAX_PAGES"].to_i
        return DEFAULT_PAGES unless configured.positive?

        configured.clamp(1, MAX_PAGES)
      end

      def transactions
        [ (DEFAULT_TRANSACTIONS * pages / DEFAULT_PAGES.to_f).round, 1 ].max
      end
    end
  end
end

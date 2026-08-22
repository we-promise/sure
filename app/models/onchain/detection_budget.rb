# frozen_string_literal: true

# How long detection may spend answering "is this address worth tracking here?".
#
# Detection runs on the request thread, and an address shape can match several
# chains, so this is what stands between a linking form and a page that hangs.
#
# Two numbers, because one is not enough. TIMEOUT is handed to the HTTP client,
# which applies it *per socket operation* — HTTParty maps it onto net/http's
# open, read and write timeouts individually, so a single probe can legitimately
# take a multiple of it. DEADLINE is therefore the one that actually bounds the
# page: probes run concurrently and are abandoned once it passes, whatever their
# client is doing.
#
# The timeout is deliberately generous. It was 5s, which sat directly on the
# median latency of one of the public explorers and turned roughly a fifth of
# probes into a timeout that read as "this wallet is empty". Being slow to
# answer and having nothing to report are different things, and the cost of
# confusing them is a wallet the user cannot link.
module Onchain
  module DetectionBudget
    DEFAULT_TIMEOUT = 10
    MAX_TIMEOUT = 30

    # Headroom over a single probe's timeout, so that a probe which is merely
    # slow still lands, while a stuck one is dropped.
    DEADLINE_HEADROOM = 2

    RETRIES = 0

    class << self
      def timeout
        configured = ENV["ONCHAIN_DETECTION_TIMEOUT"].to_i
        return DEFAULT_TIMEOUT unless configured.positive?

        configured.clamp(1, MAX_TIMEOUT)
      end

      def deadline
        timeout + DEADLINE_HEADROOM
      end

      def retries
        RETRIES
      end
    end
  end
end

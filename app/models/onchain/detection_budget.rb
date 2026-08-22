# frozen_string_literal: true

# How long a chain may take to answer "is this address worth tracking here?".
#
# Detection runs on the request thread: an address shape can match several
# chains, and each candidate is asked in turn, so the page's latency is the sum
# of every answer. A sync's budget is the wrong one here — a source that retries
# a rate limit with backoff holds the request for two minutes per chain, and a
# 0x address has six candidates.
#
# So detection gets one short attempt and no retry. A chain that cannot answer
# in time is reported as "no activity found", which is not a failure: when no
# candidate answers, the user is asked to choose, which is the same screen an
# ambiguous answer produces.
module Onchain
  module DetectionBudget
    DEFAULT_TIMEOUT = 5
    MAX_TIMEOUT = 30
    RETRIES = 0

    class << self
      def timeout
        configured = ENV["ONCHAIN_DETECTION_TIMEOUT"].to_i
        return DEFAULT_TIMEOUT unless configured.positive?

        configured.clamp(1, MAX_TIMEOUT)
      end

      def retries
        RETRIES
      end
    end
  end
end

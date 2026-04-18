class SimplefinAccount
  # Value object summarising the activity state of a SimpleFIN account's raw
  # transactions payload. Used by the setup UI to help users distinguish live
  # from dormant accounts, and by the ReplacementDetector to spot cards that
  # have likely been replaced.
  class ActivitySummary
    DEFAULT_WINDOW_DAYS = 60

    def initialize(transactions)
      @transactions = Array(transactions).compact
    end

    def last_transacted_at
      return @last_transacted_at if defined?(@last_transacted_at)
      @last_transacted_at = @transactions.filter_map { |tx| transacted_at(tx) }.max
    end

    def days_since_last_activity(now: Time.current)
      return nil unless last_transacted_at
      ((now.to_i - last_transacted_at.to_i) / 86_400).floor
    end

    def recent_transaction_count(days: DEFAULT_WINDOW_DAYS)
      cutoff = days.days.ago
      @transactions.count { |tx| (ts = transacted_at(tx)) && ts >= cutoff }
    end

    def recently_active?(days: DEFAULT_WINDOW_DAYS)
      recent_transaction_count(days: days).positive?
    end

    def dormant?(days: DEFAULT_WINDOW_DAYS)
      !recently_active?(days: days)
    end

    def transaction_count
      @transactions.size
    end

    private
      # Extract a Time for sorting/windowing. Prefer transacted_at (SimpleFIN
      # authored timestamp), fall back to posted. Zero values mean "unknown"
      # in SimpleFIN (e.g., pending transactions have posted=0) and are ignored.
      # Note: integer 0 is truthy in Ruby, so a plain `|| fallback` short-circuits
      # and never falls back. Use explicit helper so transacted_at=0 properly
      # yields to posted.
      def transacted_at(tx)
        return nil unless tx.is_a?(Hash) || tx.respond_to?(:[])
        value = timestamp_value(fetch(tx, "transacted_at")) ||
                timestamp_value(fetch(tx, "posted"))
        return nil unless value
        Time.at(value)
      rescue StandardError
        nil
      end

      def timestamp_value(raw)
        return nil if raw.blank?
        value = raw.to_i
        value.zero? ? nil : value
      end

      def fetch(tx, key)
        tx[key] || tx[key.to_sym]
      end
  end
end

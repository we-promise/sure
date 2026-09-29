class RecurringTransaction
  # The full detection pipeline -- identify patterns, materialize occurrence
  # windows, repair provider-replaced entries, match payments, detect price
  # changes -- in one place for its three callers: the post-sync job, the
  # Settings "Identify Patterns" button, and the Bills page's detection action.
  #
  # `run!` returns the identified pattern count. `backfill: true` additionally
  # reconstructs recent history after the five stages; user-triggered detection
  # asks for it, background syncs never do. `run_with_lock!` returns the count,
  # or nil when another run already holds the family lock.
  class Pipeline
    FIRST_RUN_BACKFILL_MONTHS = 6

    attr_reader :family

    def initialize(family)
      @family = family
    end

    def run!(backfill: false)
      patterns_count = Identifier.new(family).identify_recurring_patterns

      family.recurring_transactions.active.find_each do |series|
        OccurrenceGenerator.new(series).generate!
      end

      matcher = Matcher.new(family)
      matcher.repair_orphans!
      matcher.run!
      PriceChangeDetector.new(family).detect!

      # Unconditional when asked: the backfiller is idempotent, so re-running
      # it reconstructs nothing twice.
      HistoryBackfiller.new(family, months: FIRST_RUN_BACKFILL_MONTHS).run! if backfill

      patterns_count
    end

    # User-triggered runs refuse to stack on top of an in-flight pipeline
    # (debounced job or nightly sweep) instead of running concurrently.
    def run_with_lock!(backfill: false)
      result = nil
      acquired = self.class.with_family_lock(family.id) { result = run!(backfill: backfill) }
      acquired ? result : nil
    end

    # One advisory lock per family, shared by every pipeline caller. Returns
    # true when the lock was acquired and the block ran.
    def self.with_family_lock(family_id)
      lock_key = advisory_lock_key(family_id)
      # One leased connection for both halves: the unlock must run on the same
      # PostgreSQL session that took the lock, and bare .connection is
      # soft-deprecated in Rails 8.1.
      connection = ActiveRecord::Base.lease_connection
      acquired = connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_lock(?)", lock_key ])
      )

      return false unless acquired

      begin
        yield
      ensure
        connection.execute(
          ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_unlock(?)", lock_key ])
        )
      end
      true
    end

    # The key string predates this class; keeping it byte-identical means an
    # upgraded deploy still serializes against jobs queued by the old build.
    def self.advisory_lock_key(family_id)
      Digest::MD5.hexdigest("recurring_transaction_identify:#{family_id}").to_i(16) % (2**31)
    end
  end
end

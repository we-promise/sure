class RecurringTransaction
  # The full detection pipeline -- identify patterns, materialize occurrence
  # windows, repair provider-replaced entries, match payments, detect price
  # changes -- in one place for its three callers: the post-sync job, the
  # Settings "Identify Patterns" button, and the Bills page's detection action.
  class Pipeline
    FIRST_RUN_BACKFILL_MONTHS = 6

    Result = Data.define(:patterns_count, :locked) do
      def locked? = locked
    end

    attr_reader :family

    def initialize(family)
      @family = family
    end

    def run!
      # Zero occurrences alongside any series is the signature of an instance
      # whose detection ran under a build that never materialized anything.
      # Captured before generation changes the answer; the backfill below then
      # reconstructs history exactly once.
      first_run = family.recurring_occurrences.none?

      patterns_count = Identifier.new(family).identify_recurring_patterns

      family.recurring_transactions.active.find_each do |series|
        OccurrenceGenerator.new(series).generate!
      end

      matcher = Matcher.new(family)
      matcher.repair_orphans!
      matcher.run!
      PriceChangeDetector.new(family).detect!

      HistoryBackfiller.new(family, months: FIRST_RUN_BACKFILL_MONTHS).run! if first_run

      Result.new(patterns_count: patterns_count, locked: false)
    end

    # User-triggered runs refuse to stack on top of an in-flight pipeline
    # (debounced job or nightly sweep) instead of running concurrently.
    def run_with_lock!
      result = nil
      acquired = self.class.with_family_lock(family.id) { result = run! }
      acquired ? result : Result.new(patterns_count: 0, locked: true)
    end

    # One advisory lock per family, shared by every pipeline caller. Returns
    # true when the lock was acquired and the block ran.
    def self.with_family_lock(family_id)
      lock_key = advisory_lock_key(family_id)
      acquired = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_lock(?)", lock_key ])
      )

      return false unless acquired

      begin
        yield
      ensure
        ActiveRecord::Base.connection.execute(
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

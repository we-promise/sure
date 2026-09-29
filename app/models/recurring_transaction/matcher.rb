class RecurringTransaction
  # Scores candidate entries against a family's open occurrences and writes
  # allocations through the Allocator: confirmed at the exact tier, suggested
  # at the high tier, nothing below. Every signal behind a score is stored on
  # the allocation so the user can see why something matched.
  #
  # Conservative by design: auto-linking needs both a high score and an
  # unambiguous winner, user corrections are permanently sticky, and a pending
  # entry is never auto-linked.
  class Matcher
    # Tier thresholds over a maximum score of ~1.0.
    EXACT_TIER = BigDecimal("0.85")
    HIGH_TIER = BigDecimal("0.60")

    # An exact-tier match only auto-links when it beats the entry's next-best
    # occurrence by this margin; anything closer is ambiguous and demotes to
    # a suggestion.
    AMBIGUITY_MARGIN = BigDecimal("0.15")

    # Learned tolerance never widens beyond this, whatever the user confirms.
    MAX_LEARNED_TOLERANCE_PCT = 25

    Candidate = Data.define(:occurrence, :entry, :confidence, :signals)

    attr_reader :family

    def self.normalize_name(name)
      name.to_s.downcase.gsub(/\s+/, " ").strip
    end

    def initialize(family)
      @family = family
    end

    # Live mode: exact tier auto-links, high tier lands in the review queue.
    def run!
      apply(collect_candidates, suggest: true)
    end

    # Backfill mode: only unambiguous exact-tier matches are written, as
    # confirmed history. Historical suggestions would bury the review queue.
    def run_backfill!
      apply(collect_candidates(include_closed_window: true), suggest: false)
    end

    # Re-attaches allocations whose entry was replaced under them: some
    # providers post a pending transaction as a new row and delete the old one,
    # nullifying the FK. Amount and date survive, so an exact re-match restores
    # the link.
    def repair_orphans!
      orphans = RecurringAllocation
                  .joins(:recurring_occurrence)
                  .includes(recurring_occurrence: :recurring_transaction)
                  .where(recurring_occurrences: { family_id: family.id })
                  .where(entry_id: nil)
                  .where(source: %w[auto_matched user_confirmed])

      orphans.find_each do |allocation|
        series = allocation.recurring_occurrence.recurring_transaction

        # Allocations store magnitudes, entries store signs: an income entry is
        # negative, so a magnitude-only lookup never found a reposted paycheck
        # and orphaned income stayed orphaned for good.
        amounts = [ allocation.source_amount, allocation.allocated_amount ].compact
        amounts = (amounts + amounts.map(&:-@)).uniq

        # Same date and amount alone can be a coincidental twin. The candidate
        # must also look like the series' own charge: the scoped account, the
        # merchant when both sides know one, and a related name otherwise. Not
        # the strict identity the live matcher uses, because a repost is the
        # one case where the descriptor legitimately mutates (POSTED suffixes,
        # PENDING prefixes), which is why this repair exists at all.
        replacement = family.entries
          .where(entryable_type: "Transaction")
          .where(currency: allocation.source_currency || allocation.currency)
          .where(date: allocation.paid_on)
          .where(amount: amounts)
          .where.not(id: RecurringAllocation.where.not(entry_id: nil).select(:entry_id))
          .then { |scope| series.account_id.present? ? scope.where(account_id: series.account_id) : scope }
          .includes(:entryable)
          .find { |entry| repair_identity?(series, entry) }

        allocation.update!(entry: replacement) if replacement
      end
    end

    # Scores one entry against one occurrence for a surface that shows a person
    # why something matches, so the picker and the auto-pipeline give the same
    # answer.
    #
    # nil means the entry could never belong to this series: a $6.44 charge from
    # another merchant is not a weak match, it is not a match at all.
    #
    # Read-only, so it is safe on a GET.
    Explanation = Data.define(:confidence, :signals)

    def explain(occurrence, entry)
      series = occurrence.recurring_transaction
      return nil unless identity_matches?(series, entry)
      return nil unless within_window?(occurrence, entry)

      confidence, signals = score(occurrence, series, entry)
      # A flat zero from `score` means the amount fell outside tolerance, and
      # that zero is the real gate: anything past the hard filters scores 0.65+.
      return nil unless confidence.positive?

      Explanation.new(confidence: confidence, signals: signals)
    end

    private
      def apply(candidates, suggest:)
        taken_entries = Set.new
        taken_occurrences = Set.new
        written = 0

        # Highest confidence claims first; each entry and occurrence is assigned
        # at most once per run. The id tiebreak only makes equally confident
        # candidates resolve deterministically, since sort_by is not stable.
        ordered = candidates.sort_by do |candidate|
          [ -candidate.confidence, candidate.occurrence.id, candidate.entry.id ]
        end

        ordered.each do |candidate|
          next if taken_entries.include?(candidate.entry.id)
          next if taken_occurrences.include?(candidate.occurrence.id)

          tier = tier_for(candidate, ordered)
          next if tier.nil?
          next if tier == :high && !suggest

          write_allocation(candidate, tier)
          taken_entries << candidate.entry.id
          taken_occurrences << candidate.occurrence.id
          written += 1
        end

        written
      end

      def tier_for(candidate, ordered)
        if candidate.confidence >= EXACT_TIER && !pending_entry?(candidate.entry) && unambiguous?(candidate, ordered)
          :exact
        elsif candidate.confidence >= HIGH_TIER
          # Suggestions render on the payment review queue, and income review
          # has no home there: a deposit either matches at the exact tier and
          # closes the payday, or waits.
          :high unless candidate.occurrence.recurring_transaction.typed_income?
        end
      end

      # A pending charge's amount can still change when it posts: suggested at
      # most, never auto-linked.
      def pending_entry?(entry)
        entry.entryable.respond_to?(:pending?) && entry.entryable.pending?
      end

      # Ambiguous when the entry scores nearly as well against another
      # occurrence: suggest rather than silently pick.
      def unambiguous?(candidate, ordered)
        runner_up = ordered.find do |other|
          other.entry.id == candidate.entry.id && other.occurrence.id != candidate.occurrence.id
        end

        runner_up.nil? || candidate.confidence - runner_up.confidence >= AMBIGUITY_MARGIN
      end

      def write_allocation(candidate, tier)
        occurrence = candidate.occurrence
        entry = candidate.entry

        Allocator.new(occurrence).allocate_matched!(
          entry: entry,
          state: tier == :exact ? "confirmed" : "suggested",
          confidence: candidate.confidence,
          signals: candidate.signals
        )
      rescue ActiveRecord::RecordNotUnique
        # Already allocated (a previous run wrote it); nothing to do.
      rescue Allocator::OverAllocationError
        # Another occurrence already claimed the entry's capacity. Skip the
        # candidate rather than aborting the run.
      end

      # The hard filters depend on the series and the entry, not the individual
      # occurrence, so they are asked once per series rather than once per cycle
      # the bill has ever had.
      def collect_candidates(include_closed_window: false)
        occurrences = open_occurrences
        return [] if occurrences.empty?

        rejected = rejected_pairs
        allocated_entry_ids = confirmed_entry_ids
        occurrences_by_series = occurrences.group_by(&:recurring_transaction_id)

        candidates = entries_for(occurrences, include_closed_window).flat_map do |entry|
          next [] if allocated_entry_ids.include?(entry.id)

          occurrences_by_series.flat_map do |series_id, series_occurrences|
            series = series_occurrences.first.recurring_transaction
            next [] if rejected.include?([ series_id, entry.id ])
            next [] unless identity_matches?(series, entry)

            series_occurrences.filter_map do |occurrence|
              next unless within_window?(occurrence, entry)

              confidence, signals = score(occurrence, series, entry)
              next if confidence < HIGH_TIER

              Candidate.new(occurrence: occurrence, entry: entry, confidence: confidence, signals: signals)
            end
          end
        end

        prune_to_nearest_per_series(candidates)
      end

      # Within one series an entry pairs only with its nearest open occurrence.
      # The cross-series ambiguity guard still applies; this stops a backlog of
      # overdue cycles from making every payment look ambiguous against itself.
      # The ambiguity guard exists for CROSS-series twins; same-series
      # assignment is date arithmetic, not a judgment call.
      def prune_to_nearest_per_series(candidates)
        candidates.group_by { |candidate| [ candidate.entry.id, candidate.occurrence.recurring_transaction_id ] }
                  .values
                  .map { |group| group.min_by { |candidate| (candidate.entry.date - candidate.occurrence.effective_due_on).to_i.abs } }
      end

      def open_occurrences
        family.recurring_occurrences
              .open_status
              .includes(recurring_transaction: :recurrence_rules)
              .reject { |occurrence| occurrence.recurring_transaction.transfer? }
      end

      def rejected_pairs
        RecurringMatchRejection
          .joins(:recurring_transaction)
          .where(recurring_transactions: { family_id: family.id })
          .pluck(:recurring_transaction_id, :entry_id)
          .to_set
      end

      def confirmed_entry_ids
        RecurringAllocation
          .joins(:recurring_occurrence)
          .where(recurring_occurrences: { family_id: family.id })
          .where(state: "confirmed")
          .where.not(entry_id: nil)
          .pluck(:entry_id)
          .to_set
      end

      # One query over the envelope of every open occurrence's window.
      def entries_for(occurrences, include_closed_window)
        window_min = occurrences.map { |occurrence| window_for(occurrence).begin }.min
        window_max = occurrences.map { |occurrence| window_for(occurrence).end }.max
        window_max = Date.current if !include_closed_window && window_max > Date.current

        family.entries
              .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
              .where(entryable_type: "Transaction")
              .where(excluded: false)
              .where(date: window_min..window_max)
              .where.not(transactions: { kind: Transaction::TRANSFER_KINDS })
              .where.not(id: RecurringAllocation.where.not(entry_id: nil).where(state: "confirmed").select(:entry_id))
              .includes(:entryable)
              .to_a
      end

      # The occurrence's date window, snooze-aware and clamped so adjacent
      # occurrences of one series can never both claim the same entry: each
      # side caps at just under half the cycle length. Overdue occurrences
      # additionally stay matchable to today -- a late payment is exactly the
      # case the overdue workflow exists for.
      def window_for(occurrence)
        @windows ||= {}
        @windows[occurrence.id] ||= begin
          series = occurrence.recurring_transaction
          cycle_days = (365.25 / series.schedule.occurrences_per_year).floor
          half_cycle = [ (cycle_days - 1) / 2, 1 ].max

          early = [ series.match_days_early, half_cycle ].min
          late = [ series.match_days_late, half_cycle ].min

          window_start = occurrence.effective_due_on - early
          window_end = occurrence.effective_due_on + late
          window_end = [ window_end, Date.current ].max if occurrence.derived_state == :overdue

          window_start..window_end
        end
      end

      def within_window?(occurrence, entry)
        window_for(occurrence).cover?(entry.date)
      end

      # Looser than identity_matches? on purpose, see repair_orphans!: a repost
      # keeps the merchant when it has one, and its name stays kin to the old
      # descriptor rather than equal to it.
      def repair_identity?(series, entry)
        if series.merchant_id.present? && entry.entryable.merchant_id.present?
          return entry.entryable.merchant_id == series.merchant_id
        end

        candidate = normalize_name(entry.name)
        known_names(series).any? do |known|
          candidate == known || candidate.start_with?(known) || known.start_with?(candidate)
        end
      end

      # Hard filters: right sign, right currency, right account when the
      # series is account-scoped, and the identifier at least plausibly
      # related (same merchant, or a name the series knows).
      def identity_matches?(series, entry)
        return false unless entry.currency == series.currency
        return false if series.account_id.present? && entry.account_id != series.account_id

        expense_series = series.amount.positive?
        return false if expense_series != entry.amount.positive?

        if series.merchant_id.present?
          entry.entryable.merchant_id == series.merchant_id
        else
          known_names(series).include?(normalize_name(entry.name))
        end
      end

      def known_names(series)
        @known_names ||= {}
        @known_names[series.id] ||= ([ series.name ] + Array(series.matcher_hints["name_aliases"]))
                                      .compact.map { |name| self.class.normalize_name(name) }.to_set
      end

      def normalize_name(name)
        self.class.normalize_name(name)
      end

      # Memoized per occurrence: resolved_expected_amount is not cached on the
      # model, and under the "last" amount strategy it runs an ordered LIMIT 1
      # plus a SUM. Scoring a list of candidates against one occurrence would
      # otherwise re-ask that question once per candidate.
      def expected_for(occurrence)
        @expected ||= {}
        @expected[occurrence.id] ||= occurrence.resolved_expected_amount
      end

      def score(occurrence, series, entry)
        signals = {}
        expected = expected_for(occurrence)

        if series.merchant_id.present?
          signals[:merchant] = 0.40
        else
          signals[:name] = 0.35
        end

        signals[:amount] = amount_score(series, expected, entry.amount.abs)
        return [ BigDecimal("0"), signals ] if signals[:amount].nil?

        signals[:date] = date_score(occurrence, entry.date)
        signals[:account] = 0.10 if entry.account_id == series.account_id || series.account_id.nil?

        [ signals.values.sum.to_d.round(4), signals ]
      end

      # Exact amount scores 0.30; within tolerance decays 0.25 -> 0.15 with
      # distance from expected; outside tolerance kills the candidate.
      def amount_score(series, expected, actual)
        return 0.30 if (actual - expected).abs < BigDecimal("0.01")

        tolerance_pct = [ series.amount_tolerance_pct, learned_tolerance(series) ].max
        band = expected.abs * (tolerance_pct / BigDecimal("100"))
        distance = (actual - expected).abs
        return nil if band.zero? || distance > band

        (0.25 - (distance / band) * 0.10).round(4)
      end

      def learned_tolerance(series)
        BigDecimal((series.matcher_hints["learned_tolerance_pct"] || 0).to_s)
      end

      # 0.20 on the due date, decaying linearly to 0.05 at the window edge.
      def date_score(occurrence, date)
        window = window_for(occurrence)
        span = [ (window.end - window.begin).to_i, 1 ].max
        distance = (date - occurrence.effective_due_on).to_i.abs

        (0.20 - ([ distance, span ].min.to_f / span) * 0.15).round(4)
      end
  end
end

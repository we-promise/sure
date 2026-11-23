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

    # A series' bank reference (the stable token in the payment note, e.g. a
    # contract number) found in an entry's note is a hard match: whatever the
    # amount, the entry belongs to the series, scores at least the exact tier
    # and beats every non-reference candidate for the same entry (see
    # Candidate#reference_matched? and #unambiguous?). Notes are written by
    # third parties, so this is bounded by the filters that stay: account, sign
    # and currency, never a transfer leg or another merchant's charge, a user's
    # rejection, an entry already confirmed to another bill, and never income or
    # an account-less series. The accepted trade-off is that a forged note on the
    # same account links a same-sign payment of any amount and date, so a
    # reference should be distinctive.
    REFERENCE_BONUS = BigDecimal("0.25")

    # A reference match ignores the date window and pairs with the nearest
    # occurrence by due date, open or paid, past or future, however far. Two
    # limits keep that bounded: a live run only looks at reference payments of
    # the last REFERENCE_LOOKBACK_DAYS (and at settled cycles up to one cadence
    # older than that, so the nearest cycle is loaded), and a payment more than
    # one cycle before the series' first cycle is left alone rather than attached
    # to a cycle that has nothing to do with it.
    REFERENCE_LOOKBACK_DAYS = 90
    MAX_CYCLE_DAYS = 366

    # Shorter references are too likely to appear in unrelated notes by chance.
    MIN_REFERENCE_LENGTH = 3

    Candidate = Data.define(:occurrence, :entry, :confidence, :signals) do
      def reference_matched?
        signals[:reference].present?
      end
    end

    attr_reader :family

    # Narrows an entries scope (joined to transactions) to those whose own note,
    # or for a transfer outflow its receiving leg's note, matches any of the
    # LIKE patterns, case-insensitively. A coarse prefilter: matched_reference
    # makes the exact call.
    def self.with_note_patterns(scope, patterns)
      own = Entry.arel_table[:notes].matches_any(patterns)
      inflow = Transfer.joins(inflow_transaction: :entry)
                       .where(Entry.arel_table[:notes].matches_any(patterns))
                       .select(:outflow_transaction_id)
      scope.where(own.or(Transaction.arel_table[:id].in(inflow.arel)))
    end

    def self.normalize_name(name)
      name.to_s.downcase.gsub(/\s+/, " ").strip
    end

    def initialize(family)
      @family = family
    end

    # Live mode: exact tier auto-links, high tier lands in the review queue.
    # Historical rows are deliberately left alone; they are backdated cycles
    # and only the backfill pass or a manual link touches them.
    def run!
      reconcile_reference_allocations!
      written = apply(collect_candidates, suggest: true)
      close_reference_settled!
      written
    end

    # Backfill mode: only unambiguous exact-tier matches are written, as
    # confirmed history. Historical suggestions would bury the review queue.
    # Historical rows are eligible here so a backdated bill can pick up the
    # payments it already had.
    def run_backfill!
      reconcile_reference_allocations!
      written = apply(
        collect_candidates(include_closed_window: true, include_historical: true),
        suggest: false
      )
      close_reference_settled!
      written
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
      return nil unless within_window?(occurrence, entry) || matched_reference(series, entry)

      confidence, signals = score(occurrence, series, entry)
      # A flat zero from `score` means the amount fell outside tolerance, and
      # that zero is the real gate: anything past the hard filters scores 0.65+.
      return nil unless confidence.positive?

      Explanation.new(confidence: [ confidence, 1 ].min, signals: signals)
    end

    private
      # A confirmed allocation the matcher wrote itself is never reconsidered as
      # a candidate, so allocations that predate a bill's reference are
      # reconciled against it here, in one pass over what the matcher wrote:
      #
      # * A payment naming another active bill's reference on the same account,
      #   or lacking the reference of a reference-only bill, is released so the
      #   right bill can link it. Only a cycle still open or current is released;
      #   settled history of older cycles is left as it is.
      # * A payment the bill's reference identified, sitting on another cycle than
      #   the one it belongs to, moves there (see target_cycle), one allocation per
      #   entry, with both cycles recomputing whether they are settled.
      #
      # Allocations a person created or confirmed are never touched. Only three
      # kinds of allocation can need either step, and only those are loaded: on a
      # reference-only bill, carrying a reference signal, or whose note names a
      # bill's reference. A family without a bank reference skips the scan.
      def reconcile_reference_allocations!
        return unless reference_bills?

        rehomes = []
        reconcilable_allocations.find_each do |allocation|
          series = allocation.recurring_occurrence.recurring_transaction
          entry = allocation.entry
          next unless series.active? && entry

          current = allocation.recurring_occurrence
          if contradicted_allocation?(series, entry)
            Allocator.new(current).unallocate!(allocation) if releasable_cycle?(current, series)
          elsif allocation.match_signals.to_h["reference"].present? && matched_reference(series, entry)
            rehomes << [ allocation, series, entry ]
          end
        end

        # Oldest payment first, each against the cycles as the moves before it
        # left them, so a backlog fills in order instead of piling onto one cycle.
        rehomes.sort_by { |_, _, entry| [ entry.date, entry.id ] }.each do |allocation, series, entry|
          rehome_reference_allocation!(allocation, series, entry)
        rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
          # The target cycle already holds this entry; leave the allocation where it is.
          next
        end
      end

      def reference_bills?
        family.recurring_transactions.active.where.not("matcher_hints->>'bank_reference' IS NULL").exists?
      end

      # The confirmed allocations the matcher wrote that reconciliation can act
      # on: those on a reference-only bill (contradicted unless the note carries
      # the reference), those a reference identified (re-homed), and those whose
      # note names some bill's reference (released from a bill it does not
      # belong to). The note test is a coarse SQL prefilter; the exact decision
      # stays in contradicted_allocation?.
      def reconcilable_allocations
        base = RecurringAllocation.confirmed
                                  .where(source: "auto_matched")
                                  .where.not(entry_id: nil)
                                  .joins(recurring_occurrence: :recurring_transaction)
                                  .where(recurring_occurrences: { family_id: family.id })

        relevant = base.where("recurring_transactions.matcher_hints->>'reference_only' = 'true'")
                       .or(base.where("recurring_allocations.match_signals->>'reference' IS NOT NULL"))

        needles = references_by_account.values.flatten(1).map(&:last).uniq
        if needles.any?
          noting_reference = self.class.with_note_patterns(
            family.entries
                  .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
                  .where(entryable_type: "Transaction", account_id: references_by_account.keys),
            like_patterns(needles)
          )
          relevant = relevant.or(base.where(entry_id: noting_reference.select(:id)))
        end

        relevant.preload(:entry, recurring_occurrence: :recurring_transaction)
      end

      def like_patterns(needles)
        needles.map { |needle| "%#{Entry.sanitize_sql_like(needle).gsub(/\s+/, '%')}%" }
      end

      def rehome_reference_allocation!(allocation, series, entry)
        current = allocation.recurring_occurrence
        target = target_cycle(series, entry)
        return if target.nil? || target.id == current.id
        return unless rehome_target?(target, current, entry)

        move_allocation!(allocation, current, target, entry)
      end

      def rehome_target?(target, current, entry)
        if target.scheduled? && within_window?(target, entry)
          target.effective_due_on < current.effective_due_on
        else
          cycle_distance(target, entry) < cycle_distance(current, entry)
        end
      end

      # Open cycles and the one a person would call the current month's; anything
      # older and settled is history.
      def releasable_cycle?(occurrence, series)
        occurrence.scheduled? || occurrence.effective_due_on > Date.current - cycle_days(series)
      end

      def cycle_days(series)
        (365.25 / series.schedule.occurrences_per_year).floor
      end

      def contradicted_allocation?(series, entry)
        if reference_only?(series)
          !reference_only_identity?(series, entry)
        else
          matched_reference(series, entry).nil? && conflicting_reference?(series, entry)
        end
      end

      # The move and both cycles' close state are one unit: occurrence row locks
      # in a fixed order, then the entry lock, as every allocator write takes
      # them. Suggestions the entry holds are dropped first, a confirmed payment
      # replaces them.
      def move_allocation!(allocation, from, to, entry)
        RecurringAllocation.transaction do
          [ from, to ].sort_by(&:id).each(&:lock!)
          Allocator.lock_entry!(entry)
          RecurringAllocation.where(entry_id: entry.id, state: "suggested").destroy_all
          allocation.update!(recurring_occurrence_id: to.id)
          [ from, to ].each { |occurrence| Allocator.new(occurrence.reload).refresh_close_state! }
        end
      end

      # The reference decides which bill, not which month: of a bill's cycles the
      # payment goes to the oldest open one whose window covers it, and only when
      # none does, to the nearest by due date.
      def target_cycle(series, entry)
        pick_cycle(series.recurring_occurrences.reload.select { |occurrence| occurrence.scheduled? || occurrence.paid? }, entry)
      end

      # An open cycle a late payment can still be for: the entry is inside its
      # window and less than a cycle past its due date, so a payment is never
      # pulled back onto a month that went unpaid long before it.
      def claimable_open?(occurrence, entry)
        occurrence.scheduled? && within_window?(occurrence, entry) &&
          (entry.date - occurrence.effective_due_on).to_i < cycle_days(occurrence.recurring_transaction)
      end

      def pick_cycle(cycles, entry)
        open_in_window = cycles.select { |occurrence| claimable_open?(occurrence, entry) }
        return open_in_window.min_by(&:effective_due_on) if open_in_window.any?

        cycles.min_by { |occurrence| [ cycle_distance(occurrence, entry), occurrence.paid? ? 1 : 0 ] }
      end

      def cycle_distance(occurrence, entry)
        (entry.date - occurrence.effective_due_on).to_i.abs
      end

      # Cycles whose payment the bank reference identified are settled whatever
      # it amounted to (Allocator#close_worthy?), but that rule only runs when an
      # allocation is written. Allocations linked before it existed, or a cycle
      # reopened since, are closed here so a rerun reconciles them.
      def close_reference_settled!
        unsettled = RecurringAllocation.confirmed
                                       .where.not("match_signals ->> 'reference' IS NULL")
                                       .select(:recurring_occurrence_id)
        family.recurring_occurrences.open_status.where(id: unsettled).find_each do |occurrence|
          Allocator.new(occurrence).refresh_close_state!
        end
      end

      def apply(candidates, suggest:)
        taken_entries = Set.new
        taken_occurrences = Set.new
        written = 0

        # A split child whose parent is also a candidate waits until every other
        # candidate had its turn: the parent claims its bill as if the split came
        # after matching, and the Allocator then refuses the child. Otherwise
        # reference matches claim first, then highest confidence; each entry is
        # assigned at most once per run, and each occurrence once, except that
        # reference matches may add further payments to an occurrence: the
        # bill's own note on a second payment in one cycle makes it an extra
        # payment, not a rival. The id tiebreak only makes equally confident
        # candidates resolve deterministically, since sort_by is not stable.
        pruned = prune_to_nearest_per_series(candidates)
        candidate_entry_ids = pruned.to_set { |candidate| candidate.entry.id }
        ordered = pruned.sort_by do |candidate|
          parent_competes = candidate_entry_ids.include?(candidate.entry.parent_entry_id)
          [ parent_competes ? 1 : 0, candidate.reference_matched? ? 0 : 1, -candidate.confidence, candidate.occurrence.id, candidate.entry.id ]
        end

        ordered.each do |candidate|
          next if taken_entries.include?(candidate.entry.id)
          next if !candidate.reference_matched? && taken_occurrences.include?(candidate.occurrence.id)

          tier = tier_for(candidate, ordered)
          next if tier.nil?
          next if tier == :high && !suggest

          next unless write_allocation(candidate, tier)

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

        return true if runner_up.nil?
        # A reference match is the entry's own series' payment; it only competes
        # with other reference matches.
        return candidate.reference_matched? if candidate.reference_matched? != runner_up.reference_matched?

        # Two bills that both matched by the same reference are told apart by how
        # well the payment fits each (amount, date, account), not by the points
        # their identity path happened to give the reference.
        return reference_fit(candidate) - reference_fit(runner_up) >= AMBIGUITY_MARGIN if candidate.reference_matched?

        candidate.confidence - runner_up.confidence >= AMBIGUITY_MARGIN
      end

      def reference_fit(candidate)
        candidate.signals.values_at(:amount, :date, :account).compact.sum.to_d
      end

      # False when the occurrence should stay open to the next candidate.
      def write_allocation(candidate, tier)
        Allocator.new(candidate.occurrence).allocate_matched!(
          entry: candidate.entry,
          state: tier == :exact ? "confirmed" : "suggested",
          # Reference bonuses can push the raw score past 1; the column is a
          # probability.
          confidence: [ candidate.confidence, 1 ].min,
          signals: candidate.signals
        )
        true
      rescue Allocator::SplitCounterpartAllocatedError
        # The other side of this split already pays a bill, so this entry is
        # not money the occurrence can have. Another charge still can.
        false
      rescue ActiveRecord::RecordNotUnique
        # Already allocated (a previous run wrote it); nothing to do.
        true
      rescue Allocator::OverAllocationError
        # Another occurrence already claimed the entry's capacity. Skip the
        # candidate rather than aborting the run.
        true
      end

      # The hard filters depend on the series and the entry, not the individual
      # occurrence, so they are asked once per series rather than once per cycle
      # the bill has ever had.
      def collect_candidates(include_closed_window: false, include_historical: false)
        occurrences = open_occurrences(include_historical: include_historical) +
                      paid_reference_occurrences(include_closed_window, include_historical: include_historical)
        return [] if occurrences.empty?

        rejected = rejected_pairs
        allocated_entry_ids = confirmed_entry_ids
        occurrences_by_series = occurrences.group_by(&:recurring_transaction_id)
        earliest_due = occurrences_by_series.transform_values { |list| list.map(&:effective_due_on).min }

        candidates = entries_for(occurrences, include_closed_window).flat_map do |entry|
          next [] if allocated_entry_ids.include?(entry.id)

          occurrences_by_series.flat_map do |series_id, series_occurrences|
            series = series_occurrences.first.recurring_transaction
            next [] if rejected.include?([ series_id, entry.id ])
            next [] unless identity_matches?(series, entry)

            # The bill's own reference on the payment pairs it with any cycle.
            reference_hit = matched_reference(series, entry).present?
            next [] if reference_hit && before_first_cycle?(series, entry, earliest_due[series_id])

            series_occurrences.filter_map do |occurrence|
              next unless reference_hit || within_window?(occurrence, entry)

              confidence, signals = score(occurrence, series, entry)
              next if confidence < HIGH_TIER
              # A settled cycle only takes further payments the bill's own
              # reference vouches for.
              next if occurrence.paid? && signals[:reference].blank?

              Candidate.new(occurrence: occurrence, entry: entry, confidence: confidence, signals: signals)
            end
          end
        end

        candidates
      end

      # Within one series an entry pairs only with its nearest open occurrence.
      # The cross-series ambiguity guard still applies; this stops a backlog of
      # overdue cycles from making every payment look ambiguous against itself.
      # The ambiguity guard exists for CROSS-series twins; same-series
      # assignment is date arithmetic, not a judgment call.
      def prune_to_nearest_per_series(candidates)
        groups = candidates.group_by { |candidate| [ candidate.entry.id, candidate.occurrence.recurring_transaction_id ] }.values
        reference_groups, plain_groups = groups.partition { |group| group.first.reference_matched? }

        picks = plain_groups.map { |group| nearest_candidate(group) }

        # A reference payment goes to the oldest open cycle whose window covers it:
        # a late payment settles the overdue month, not the nearer next one. Oldest
        # payment first, each cycle taking one, so a backlog fills in order instead
        # of every payment claiming the oldest cycle; with no open cycle left in
        # reach the payment goes to the nearest, as any other payment does.
        claimed = Set.new
        reference_groups.sort_by { |group| [ group.first.entry.date, group.first.entry.id ] }.each do |group|
          open_in_window = group.select { |candidate| !claimed.include?(candidate.occurrence.id) && claimable_open?(candidate.occurrence, candidate.entry) }
          pick = open_in_window.min_by { |candidate| candidate.occurrence.effective_due_on } || nearest_candidate(group)
          claimed << pick.occurrence.id
          picks << pick
        end

        picks
      end

      # Ties go to the occurrence still open.
      def nearest_candidate(group)
        group.min_by { |candidate| [ (candidate.entry.date - candidate.occurrence.effective_due_on).to_i.abs, candidate.occurrence.paid? ? 1 : 0 ] }
      end

      # Cycles of an ended series take no payments: such a series is usually the
      # superseded twin of an active one and would only make every payment look
      # ambiguous. Paused and inactive series keep theirs, so a late payment
      # still reaches a paused bill's overdue leftover.
      def open_occurrences(include_historical: false)
        scope = include_historical ? family.recurring_occurrences.open_status : family.recurring_occurrences.current_open

        scope.joins(:recurring_transaction)
             .where.not(recurring_transactions: { status: "ended" })
             .includes(recurring_transaction: :recurrence_rules)
             .to_a
      end

      # Settled cycles of bills that carry a bank reference stay candidates for
      # further reference payments (a second payment in the same month). A live
      # run only sees payments from the last REFERENCE_LOOKBACK_DAYS, so a cycle
      # can only be the nearest one for them if it is at most one cadence older
      # than that; backfill takes all history.
      def paid_reference_occurrences(include_closed_window, include_historical: false)
        scope = family.recurring_occurrences
                      .paid
                      .joins(:recurring_transaction)
                      .merge(RecurringTransaction.active)
                      .where.not("recurring_transactions.matcher_hints->>'bank_reference' IS NULL")
        scope = scope.where(historical: false) unless include_historical
        scope = scope.includes(recurring_transaction: :recurrence_rules)
        return scope.to_a if include_closed_window

        scope.where("recurring_occurrences.due_on >= ?", (REFERENCE_LOOKBACK_DAYS + MAX_CYCLE_DAYS).days.ago.to_date).select do |occurrence|
          occurrence.due_on >= (REFERENCE_LOOKBACK_DAYS + cycle_days(occurrence.recurring_transaction)).days.ago.to_date
        end
      end

      def rejected_pairs
        RecurringMatchRejection
          .joins(:recurring_transaction)
          .where(recurring_transactions: { family_id: family.id })
          .pluck(:recurring_transaction_id, :entry_id)
          .to_set
      end

      # Confirmed payments that spoke for an entry. Allocations of an ended
      # series (a deleted or dismissed bill) are tombstones the Allocator
      # ignores too, so an active series can still take the entry.
      def confirmed_allocations
        Allocator.active_allocations(RecurringAllocation.confirmed.where.not(entry_id: nil))
                 .where(recurring_occurrences: { family_id: family.id })
      end

      def confirmed_entry_ids
        confirmed_allocations.pluck(:entry_id).to_set
      end

      # One query over the envelope of every open occurrence's window.
      # Transfer legs are left out, except the outflow side of a transfer that
      # a recurring transfer series could be paid by. A split charge stays in:
      # its parent is excluded by the split, not by the user, and is the payment.
      def entries_for(occurrences, include_closed_window)
        window_min = occurrences.map { |occurrence| window_for(occurrence).begin }.min
        window_max = occurrences.map { |occurrence| window_for(occurrence).end }.max
        window_max = Date.current if !include_closed_window && window_max > Date.current

        reference_floor = if include_closed_window
          occurrences.map(&:effective_due_on).min - 400
        else
          REFERENCE_LOOKBACK_DAYS.days.ago.to_date
        end

        source_account_ids = occurrences.map(&:recurring_transaction).select(&:transfer?).map(&:account_id).uniq
        preload_transfer_destinations(source_account_ids, [ window_min, reference_floor ].min..[ window_max, Date.current ].max)

        candidates_scope = family.entries
                                 .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
                                 .where(entryable_type: "Transaction")
                                 .not_excluded_or_split_parent
                                 .where("transactions.kind NOT IN (?) OR transactions.id IN (?)", Transaction::TRANSFER_KINDS, transfer_destinations.keys)
                                 .where.not(id: confirmed_allocations.select(:entry_id))
                                 .includes(:entryable)

        by_window = candidates_scope.where(date: window_min..window_max).to_a
        (by_window + reference_entries(candidates_scope, occurrences, reference_floor)).uniq(&:id)
      end

      # Entries whose note carries a bill's reference, wherever they fall in
      # time: they are not inside any window by definition. The SQL is a coarse
      # prefilter; matched_reference makes the exact whitespace-insensitive call.
      def reference_entries(scope, occurrences, floor)
        series_list = occurrences.map(&:recurring_transaction).uniq.select { |series| series.account_id.present? && !series.typed_income? }
        needles = series_list.filter_map { |series| series.bank_reference && normalize_name(series.bank_reference) }
                             .select { |needle| needle.length >= MIN_REFERENCE_LENGTH }.uniq
        return [] if needles.empty?

        # A recurring transfer's reference may sit on the receiving leg only.
        self.class.with_note_patterns(scope.where(account_id: series_list.map(&:account_id).uniq).where(entries: { date: floor..Date.current }), like_patterns(needles)).to_a
      end

      # More than one cycle before the series' first cycle: a payment from before
      # the bill existed in this app, not that cycle's payment.
      def before_first_cycle?(series, entry, earliest_due)
        return false if earliest_due.nil?

        cycle_days = (365.25 / series.schedule.occurrences_per_year).floor
        entry.date < earliest_due - cycle_days
      end

      # Outflow transaction id => the account its transfer pays into, for the
      # transfers leaving the given accounts in the window. Every entry
      # candidate collection scores is in that window, so once this has run the
      # map is complete and a missing entry is simply not a transfer outflow.
      def preload_transfer_destinations(account_ids, dates)
        @transfer_destinations_complete = true
        return if account_ids.empty?

        Transfer
          .joins(outflow_transaction: :entry)
          .joins("INNER JOIN entries inflow_entries ON inflow_entries.entryable_id = transfers.inflow_transaction_id AND inflow_entries.entryable_type = 'Transaction'")
          .where(entries: { account_id: account_ids, date: dates })
          .pluck(:outflow_transaction_id, "inflow_entries.account_id", "inflow_entries.notes")
          .each do |outflow_id, account_id, notes|
            transfer_destinations[outflow_id] = account_id
            transfer_inflow_notes[outflow_id] = notes
          end
      end

      def transfer_destinations
        @transfer_destinations ||= {}
      end

      # Outflow transaction id => the note on the receiving side of its
      # transfer, filled alongside transfer_destinations.
      def transfer_inflow_notes
        @transfer_inflow_notes ||= {}
      end

      # The account the entry pays into when it is the outflow of a transfer.
      # Read from the preload during candidate collection; looked up on demand
      # for explain and orphan repair, which handle one entry at a time.
      def transfer_destination(entry)
        transaction_id = entry.entryable_id
        return transfer_destinations[transaction_id] if transfer_destinations.key?(transaction_id) || @transfer_destinations_complete

        account_id, notes = Transfer
          .where(outflow_transaction_id: transaction_id)
          .joins(inflow_transaction: :entry)
          .pick("entries.account_id", "entries.notes")
        transfer_inflow_notes[transaction_id] = notes
        transfer_destinations[transaction_id] = account_id
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
          if occurrence.derived_state.in?([ :overdue, :historical ])
            window_end = [ window_end, Date.current ].max
          end

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
        # The hard filters of identity_matches? hold for a repost too: a payment
        # of the other sign, or a transfer leg of an ordinary bill, is never it.
        return false if series.amount.positive? != entry.amount.positive?
        return false if !series.transfer? && entry.entryable.transfer?

        # A transfer leg's name is generic ("Transfer", a bank reference), so
        # the account pair is the identity here too, as in identity_matches?.
        return reference_only_identity?(series, entry) if reference_only?(series)
        return transfer_destination(entry) == series.destination_account_id if series.transfer?
        return true if reference_identity?(series, entry)

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
      # related (same merchant, a name the series knows, or the series' bank
      # reference in the entry's note). A recurring
      # transfer is identified by its account pair instead: the entry must be
      # the outflow of a transfer into the series' destination account. Any
      # other series never matches a transfer leg.
      def identity_matches?(series, entry)
        return false unless entry.currency == series.currency
        return false if series.account_id.present? && entry.account_id != series.account_id

        expense_series = series.amount.positive?
        return false if expense_series != entry.amount.positive?

        return reference_only_identity?(series, entry) if reference_only?(series)
        return transfer_destination(entry) == series.destination_account_id if series.transfer?
        return false if entry.entryable.transfer?
        return true if reference_identity?(series, entry)

        if series.merchant_id.present?
          entry.entryable.merchant_id == series.merchant_id
        else
          known_names(series).include?(normalize_name(entry.name))
        end
      end

      # The user's own bank reference found in the note identifies the payee, so a
      # bill named freely ("Strom") still finds its payment ("Example Energy").
      # Bounded like every reference effect (see matched_reference), and a merchant
      # the series is explicitly bound to is never overridden: an entry carrying a
      # different merchant is that merchant's charge whatever its note says. An
      # entry without a merchant has made no contrary claim.
      def reference_identity?(series, entry)
        return false if matched_reference(series, entry).nil?

        entry_merchant_id = entry.entryable.merchant_id
        !(series.merchant_id.present? && entry_merchant_id.present? && entry_merchant_id != series.merchant_id)
      end

      # "Match by reference only": the note's reference is the whole identity.
      # Only effective where a reference can match at all (see matched_reference),
      # otherwise the series keeps its ordinary identity rather than matching
      # nothing.
      def reference_only?(series)
        series.reference_only? && !series.typed_income? && series.account_id.present?
      end

      # A recurring transfer additionally keeps its account pair; for every other
      # series name and merchant are not compared at all.
      def reference_only_identity?(series, entry)
        if series.transfer?
          return false unless transfer_destination(entry) == series.destination_account_id
        elsif entry.entryable.transfer?
          return false
        end

        matched_reference(series, entry).present?
      end

      def known_names(series)
        @known_names ||= {}
        @known_names[series.id] ||= series.known_names
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
        reference = matched_reference(series, entry)

        # Another bill's reference on this payment, and not this bill's own,
        # excludes the candidate outright.
        return [ BigDecimal("0"), signals ] if reference.nil? && conflicting_reference?(series, entry)

        identity_key, identity_weight = if series.transfer?
          [ :transfer, 0.40 ]
        elsif series.merchant_id.present?
          [ :merchant, 0.40 ]
        else
          [ :name, 0.35 ]
        end
        reference_only = reference_only?(series)
        # Reference-only: the reference takes the identity's points below, and
        # name or merchant give no signal.
        signals[identity_key] = identity_weight unless reference_only

        signals[:amount] = amount_score(series, expected, entry.amount.abs)
        if signals[:amount].nil?
          # Outside tolerance kills a candidate, unless the reference vouches
          # for it: then the amount is only a fact about this payment (shown as
          # "off by"), worth no points.
          return [ BigDecimal("0"), signals ] unless reference

          signals[:amount] = 0.0
        end

        signals[:date] = date_score(occurrence, entry.date)
        signals[:account] = 0.10 if entry.account_id == series.account_id || series.account_id.nil?

        total = signals.values.sum.to_d
        if reference
          total += reference_only ? identity_weight.to_d : REFERENCE_BONUS
          # Whatever the amount scored, a reference match is at least exact tier.
          total = [ total, EXACT_TIER ].max
          # Only the configured reference is stored, never the note it was found in.
          signals[:reference] = reference
        end

        [ total.round(4), signals ]
      end

      # The series' configured bank reference when the entry's note carries it,
      # else nil. Needs an account-scoped, non-income series: income notes come
      # from the payer and income never reaches the review queue, so a spoofed
      # deposit note would only ever be able to auto-link, and without an account
      # nothing anchors the claim.
      def matched_reference(series, entry)
        return nil if series.typed_income? || series.account_id.blank?

        reference = series.bank_reference
        return nil if reference.nil?

        needle = normalize_name(reference)
        return nil if needle.length < MIN_REFERENCE_LENGTH

        reference if note_texts(series, entry).any? { |text| normalize_name(text).include?(needle) }
      end

      # Another active bill on the entry's account carries a reference the note
      # names, and this series' own reference did not match.
      def conflicting_reference?(series, entry)
        return false if series.typed_income?

        others = references_by_account[entry.account_id]
        return false if others.blank?

        texts = note_texts(series, entry).map { |text| normalize_name(text) }
        others.any? { |series_id, needle| series_id != series.id && texts.any? { |text| text.include?(needle) } }
      end

      # The entry's own note, plus the receiving side's for a recurring transfer
      # (either leg's bank text may carry the reference).
      def note_texts(series, entry)
        texts = [ entry.notes ]
        if series.transfer? && transfer_destination(entry)
          texts << transfer_inflow_notes[entry.entryable_id]
        end
        texts.compact_blank
      end

      # account_id => [[series id, normalized reference]] over active non-income
      # series, for the cross-series conflict check.
      def references_by_account
        @references_by_account ||= family.recurring_transactions.active
          .where.not(account_id: nil)
          .where.not("matcher_hints->>'bank_reference' IS NULL")
          .reject(&:typed_income?)
          .filter_map do |other|
            needle = normalize_name(other.bank_reference)
            [ other.account_id, [ other.id, needle ] ] if needle.length >= MIN_REFERENCE_LENGTH
          end
          .group_by(&:first)
          .transform_values { |pairs| pairs.map(&:last) }
      end

      # Exact amount scores 0.30; within tolerance decays 0.25 -> 0.15 with
      # distance from expected; outside tolerance kills the candidate.
      def amount_score(series, expected, actual)
        return 0.30 if (actual - expected).abs < BigDecimal("0.01")

        tolerance_pct = series.effective_amount_tolerance_pct
        band = expected.abs * (tolerance_pct / BigDecimal("100"))
        distance = (actual - expected).abs
        return nil if band.zero? || distance > band

        (0.25 - (distance / band) * 0.10).round(4)
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

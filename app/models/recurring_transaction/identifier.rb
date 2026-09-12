class RecurringTransaction
  # Bills subsystem: detection now clusters amounts within a tolerance rather
  # than requiring an exact match, claims existing series instead of duplicating
  # them, lands unclaimed patterns as `suggested`, and offers candidate patterns
  # to the add-bill pickers.
  class Identifier
    attr_reader :family

    def initialize(family)
      @family = family
    end

    # Amounts within this percentage of a cluster's running mean belong to the
    # same obligation, so a price creep stays one series instead of forking a
    # new row per price. Mirrors the recurring_transactions.amount_tolerance_pct
    # column default.
    DEFAULT_TOLERANCE_PCT = 7.5

    # Sub-dollar patterns (penny vault transfers, rounding sweeps) are never
    # worth offering as a bill or income starting point.
    MINIMUM_CANDIDATE_AMOUNT = 1

    # Read-only: recurring-shaped patterns NOT already covered by an
    # existing series, for the add-dialog picker. Two consistent
    # occurrences are enough to OFFER a candidate (the automatic pipeline
    # keeps requiring three to act on its own).
    def candidate_patterns(sign: :outflow, min_occurrences: 2)
      wanted_negative = sign == :inflow
      existing_by_identity = family.recurring_transactions.to_a.group_by { |recurring| identity_key(recurring) }

      collect_patterns(min_occurrences: min_occurrences).select do |pattern|
        next false unless pattern[:amount].negative? == wanted_negative
        next false if pattern[:expected_amount_avg].abs < MINIMUM_CANDIDATE_AMOUNT

        identity = [ pattern[:merchant_id] ? [ :merchant, pattern[:merchant_id] ] : [ :name, pattern[:name] ],
                     pattern[:currency], pattern[:account_id], nil ]
        candidates = existing_by_identity[identity] || []
        nearest_within_tolerance(candidates, pattern[:expected_amount_avg]).nil?
      end
    end

    # Income candidates are source-based, not amount-clustered: a variable
    # paycheck (weekly hours) never forms an amount cluster and rarely
    # lands on the same day of the month, but several deposits from one
    # source inside the lookback is exactly what a payday source looks
    # like. Bills keep the stricter pattern shape via candidate_patterns.
    def income_source_candidates(lookback: 90.days, min_occurrences: 2)
      declared_income = family.recurring_transactions.where(bill_type: "income").to_a

      inflows = family.entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
        .where(entryable_type: "Transaction")
        .where("entries.date >= ?", lookback.ago.to_date)
        .where("entries.amount < 0")
        .where.not("transactions.kind": Transaction::TRANSFER_KINDS)
        .includes(:entryable)
        .to_a

      inflows
        .group_by do |entry|
          transaction = entry.entryable
          identifier = transaction.merchant_id.present? ? [ :merchant, transaction.merchant_id ] : [ :name, entry.name ]
          [ identifier, entry.currency, entry.account_id ]
        end
        .filter_map do |(identifier, currency, account_id), group|
          next if group.size < min_occurrences

          amounts = group.map { |entry| entry.amount.abs }
          next if (amounts.sum / amounts.size) < MINIMUM_CANDIDATE_AMOUNT
          next if claimed_income_source?(declared_income, identifier, currency, account_id)

          last_occurrence = group.max_by(&:date)

          {
            name: identifier.first == :name ? identifier.last : nil,
            merchant_id: identifier.first == :merchant ? identifier.last : nil,
            currency: currency,
            account_id: account_id,
            amount: last_occurrence.amount,
            expected_amount_avg: -(amounts.sum / amounts.size),
            last_occurrence_date: last_occurrence.date,
            occurrence_count: group.size,
            entries: group
          }
        end
        .sort_by { |candidate| -candidate[:entries].sum { |entry| entry.amount.abs } }
    end

    # Identify and create/update recurring transactions for the family
    def identify_recurring_patterns
      three_months_ago = 3.months.ago.to_date
      recurring_patterns = collect_patterns(min_occurrences: 3)

      # Claim-or-create. Existing rows are grouped by identity (merchant or
      # name, currency, account) and each pattern claims the nearest existing
      # series whose amount sits within tolerance -- INCLUDING manual and
      # ended rows, so detection can never recreate a bill the user already
      # declared by hand or dismissed. Only an unclaimed pattern creates a
      # row, and it lands as `suggested`, awaiting confirmation.
      existing_by_identity = family.recurring_transactions.to_a.group_by { |recurring| identity_key(recurring) }

      recurring_patterns.each do |pattern|
        identity = [ pattern[:merchant_id] ? [ :merchant, pattern[:merchant_id] ] : [ :name, pattern[:name] ],
                     pattern[:currency], pattern[:account_id], nil ]
        candidates = existing_by_identity[identity] || []
        claimed = nearest_within_tolerance(candidates, pattern[:expected_amount_avg])

        if claimed
          # Manual rows are refreshed by the dedicated variance pass; ended
          # rows are tombstones (the user dismissed or cancelled the bill).
          next if claimed.manual? || claimed.ended?

          update_claimed_series(claimed, pattern)
          next
        end

        begin
          created = create_suggested_series(pattern, scoped: candidates.any?)
          (existing_by_identity[identity] ||= []) << created
        rescue ActiveRecord::RecordNotUnique
          # Race: another process created the same identity between load and
          # save. Re-read and treat it as the claimed series.
          racer = family.recurring_transactions.find_by(identity_conditions(pattern, scoped: candidates.any?))
          next unless racer
          next if racer.manual? || racer.ended?

          update_claimed_series(racer, pattern)
        end
      end

      # Also check for manual recurring transactions that might need variance updates
      update_manual_recurring_transactions(three_months_ago)

      recurring_patterns.size
    end

    # Update variance for existing manual recurring transactions.
    #
    # Transfer rows (destination_account_id present) are skipped: their
    # variance / occurrence tracking would need pair-detection across
    # both endpoints rather than the single-account name/merchant match
    # the helper performs. Issue #1590 tracks the proper Cleaner-aware
    # matching for recurring transfers.
    def update_manual_recurring_transactions(_since_date)
      manual_recurring_transactions = family.recurring_transactions
        .where(manual: true, status: "active", destination_account_id: nil)
        .includes(:account)
        .to_a

      matching_entries_by_recurring_id = matching_entries_by_manual_recurring_id(
        manual_recurring_transactions,
        lookback_months: 6
      )

      manual_recurring_transactions.each do |recurring|
        matching_entries = matching_entries_by_recurring_id.fetch(recurring.id, [])
        next if matching_entries.empty?

        # Extract amounts and dates from all matching entries
        matching_amounts = matching_entries.map(&:amount)
        last_entry = matching_entries.max_by(&:date)

        # Recalculate variance from all occurrences (including identical amounts)
        # The series' own schedule computes the next date so a manual row
        # with weekly or other non-monthly rules advances on its real
        # cadence; legacy monthly rows keep byte-identical behavior.
        recurring.update!(
          expected_amount_min: matching_amounts.min,
          expected_amount_max: matching_amounts.max,
          expected_amount_avg: matching_amounts.sum / matching_amounts.size,
          occurrence_count: matching_amounts.size,
          last_occurrence_date: last_entry.date,
          next_expected_date: recurring.schedule.next_occurrence_after(last_entry.date)
        )
      end
    end

    private
      # Identity as the unique indexes see it, minus dedup_scope: several
      # series can legitimately share this key (subscription tiers), which is
      # exactly why claiming goes through amount-nearness rather than lookup.
      def identity_key(recurring)
        identifier = recurring.merchant_id.present? ? [ :merchant, recurring.merchant_id ] : [ :name, recurring.name ]
        [ identifier, recurring.currency, recurring.account_id, recurring.destination_account_id ]
      end

      # Shared pattern collection: groups three months of non-transfer
      # entries by identity, clusters amounts within tolerance, and keeps
      # clusters that recur on a consistent day. The caller decides how many
      # occurrences constitute a pattern.
      def collect_patterns(min_occurrences:)
        three_months_ago = 3.months.ago.to_date

        # Skip transfer-kind transactions: they're one half of a Transfer pair, so grouping them
        # under their single account would produce incoherent recurring "patterns" that don't
        # represent the underlying account-pair flow. Recurring transfers are tracked on a
        # different shape (RecurringTransaction with destination_account_id). Filtering at the
        # SQL level avoids loading and discarding transfer entries for a busy family.
        entries_with_transactions = family.entries
          .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
          .where(entryable_type: "Transaction")
          .where("entries.date >= ?", three_months_ago)
          .where.not("transactions.kind": Transaction::TRANSFER_KINDS)
          .includes(:entryable)
          .to_a

        # Group by merchant (if present) or name, plus currency and account --
        # deliberately NOT by amount. Amounts are clustered within tolerance
        # inside each group, so three subscription tiers to one merchant remain
        # three patterns while a price creep stays one.
        grouped_transactions = entries_with_transactions
          .select { |entry| entry.entryable.is_a?(Transaction) }
          .group_by do |entry|
            transaction = entry.entryable
            identifier = transaction.merchant_id.present? ? [ :merchant, transaction.merchant_id ] : [ :name, entry.name ]
            [ identifier, entry.currency, entry.account_id ]
          end

        patterns = []

        grouped_transactions.each do |(identifier, currency, account_id), entries|
          cluster_by_amount(entries).each do |cluster|
            next if cluster.size < min_occurrences

            # Check if the last occurrence was within the last 45 days
            last_occurrence = cluster.max_by(&:date)
            next if last_occurrence.date < 45.days.ago.to_date

            # Check if transactions occur on similar days (within 5 days of each other)
            days_of_month = cluster.map { |e| e.date.day }.sort
            next unless days_cluster_together?(days_of_month)

            amounts = cluster.map(&:amount)
            identifier_type, identifier_value = identifier

            pattern = {
              # The most recent charge is the current price; the cluster's
              # spread is recorded as the variance band.
              amount: last_occurrence.amount,
              expected_amount_min: amounts.min,
              expected_amount_max: amounts.max,
              expected_amount_avg: amounts.sum / amounts.size,
              currency: currency,
              account_id: account_id,
              expected_day_of_month: calculate_expected_day(days_of_month),
              last_occurrence_date: last_occurrence.date,
              occurrence_count: cluster.size,
              entries: cluster
            }

            if identifier_type == :merchant
              pattern[:merchant_id] = identifier_value
            else
              pattern[:name] = identifier_value
            end

            patterns << pattern
          end
        end

        patterns
      end

      # Splits a group's entries into amount clusters: sorted by amount, an
      # entry joins the current cluster while it sits within tolerance of the
      # cluster's running mean, else starts a new one. Comparing against the
      # mean (not the neighbor) stops a chain of small steps from drifting one
      # cluster across genuinely different prices.
      def cluster_by_amount(entries)
        clusters = []

        entries.sort_by(&:amount).each do |entry|
          current = clusters.last

          if current && within_tolerance?(cluster_mean(current), entry.amount)
            current << entry
          else
            clusters << [ entry ]
          end
        end

        clusters
      end

      def cluster_mean(cluster)
        cluster.sum(&:amount) / cluster.size
      end

      def within_tolerance?(reference, amount)
        (amount - reference).abs <= reference.abs * (DEFAULT_TOLERANCE_PCT / 100.0)
      end

      # A payday source is claimed by ANY declared income series sharing its
      # identity, regardless of amount: variable pay means amount-nearness is
      # meaningless for income.
      def claimed_income_source?(declared_income, identifier, currency, account_id)
        identifier_type, identifier_value = identifier

        declared_income.any? do |recurring|
          next false unless recurring.currency == currency
          next false if recurring.account_id.present? && recurring.account_id != account_id

          if identifier_type == :merchant
            recurring.merchant_id == identifier_value
          else
            recurring.merchant_id.nil? && recurring.name == identifier_value
          end
        end
      end

      def nearest_within_tolerance(candidates, target_amount)
        candidates
          .select { |recurring| within_tolerance?(target_amount, recurring.amount) }
          .min_by { |recurring| (recurring.amount - target_amount).abs }
      end

      # Refreshes a claimed series' cadence bookkeeping and variance band.
      # Amount and status are left alone (price changes belong to
      # PriceChangeDetector), and so is the due day once the user has pinned
      # the schedule.
      def update_claimed_series(recurring, pattern)
        # A detected day shift lands before the date math, so the persisted
        # next_expected_date agrees with the regenerated occurrences instead
        # of keeping the old day for a cycle.
        recurring.last_occurrence_date = pattern[:last_occurrence_date]
        unless recurring.schedule_pinned?
          recurring.expected_day_of_month = pattern[:expected_day_of_month]
          sync_monthly_rule_day(recurring, pattern[:expected_day_of_month])
        end

        recurring.update!(
          last_occurrence_date: pattern[:last_occurrence_date],
          next_expected_date: recurring.schedule.next_occurrence_after(pattern[:last_occurrence_date]),
          occurrence_count: pattern[:occurrence_count],
          expected_amount_min: pattern[:expected_amount_min],
          expected_amount_max: pattern[:expected_amount_max],
          expected_amount_avg: pattern[:expected_amount_avg]
        )
      end

      # Scheduling reads recurrence_rules, not expected_day_of_month, so a
      # detected day shift must move the rule and regenerate future occurrences.
      def sync_monthly_rule_day(recurring, day)
        rules = recurring.recurrence_rules
        return unless rules.size == 1

        rule = rules.first
        return unless rule.frequency == "monthly" && rule.interval == 1
        return if rule.day_of_month.blank? || rule.day_of_month == RecurrenceRule::LAST
        return if rule.day_of_month == day

        rule.update!(day_of_month: day)
        # When the day column itself is about to change, the model's own
        # after_commit regenerates once on save. The explicit pass is only
        # for a rule that drifted out of agreement with an unchanged column.
        OccurrenceGenerator.new(recurring).regenerate_future! unless recurring.will_save_change_to_expected_day_of_month?
      end

      def create_suggested_series(pattern, scoped:)
        account = pattern[:account_id] && Account.find_by(id: pattern[:account_id])
        classification = Classifier.classify(
          name: pattern[:name] || pattern[:entries].first.name,
          entries: pattern[:entries],
          account: account
        )
        income = pattern[:amount].negative?

        family.recurring_transactions.create!(
          identity_conditions(pattern, scoped: scoped).merge(
            amount: pattern[:amount],
            expected_amount_min: pattern[:expected_amount_min],
            expected_amount_max: pattern[:expected_amount_max],
            expected_amount_avg: pattern[:expected_amount_avg],
            expected_day_of_month: pattern[:expected_day_of_month],
            last_occurrence_date: pattern[:last_occurrence_date],
            next_expected_date: calculate_next_expected_date(pattern[:last_occurrence_date], pattern[:expected_day_of_month]),
            occurrence_count: pattern[:occurrence_count],
            status: "suggested",
            bill_type: income ? "income" : classification.bill_type,
            category_id: income ? nil : classification.category_id,
            autopay: income ? false : classification.autopay,
            manual: false
          )
        )
      end

      # A second series for an already-taken identity is distinguished by
      # stamping the cluster's mean amount into dedup_scope.
      def identity_conditions(pattern, scoped:)
        {
          currency: pattern[:currency],
          account_id: pattern[:account_id],
          merchant_id: pattern[:merchant_id],
          name: pattern[:merchant_id].present? ? nil : pattern[:name],
          dedup_scope: scoped ? pattern[:expected_amount_avg].round(2).to_s("F") : ""
        }
      end

      def matching_entries_by_manual_recurring_id(recurring_transactions, lookback_months:)
        return {} if recurring_transactions.empty?

        lookback_date = lookback_months.months.ago.to_date
        currencies = recurring_transactions.map(&:currency).uniq
        account_ids = recurring_transactions.filter_map(&:account_id).uniq

        entries = family.entries
          .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
          .where(entries: { entryable_type: "Transaction", currency: currencies })
          .where("entries.date >= ?", lookback_date)
          .select("entries.*, transactions.merchant_id AS transaction_merchant_id")
          .order(date: :desc)

        # Legacy manual rows without account_id can match any account in the
        # family, so only push account filtering into SQL when every row is
        # account-scoped.
        if account_ids.any? && recurring_transactions.all? { |recurring| recurring.account_id.present? }
          entries = entries.where(entries: { account_id: account_ids })
        end

        candidate_entries = entries.to_a

        recurring_transactions.to_h do |recurring|
          [
            recurring.id,
            candidate_entries.select { |entry| manual_recurring_matches_entry?(recurring, entry) }
          ]
        end
      end

      def manual_recurring_matches_entry?(recurring, entry)
        return false unless entry.currency == recurring.currency
        return false if recurring.account_id.present? && entry.account_id != recurring.account_id
        # Anchor on the row's stable, user-set seed amount (not
        # expected_amount_avg, which the very corruption we're guarding
        # against here could already have skewed) so unrelated charges that
        # happen to share a merchant/day don't get averaged in (issue #2936
        # follow-up).
        return false unless RecurringTransaction.amount_within_variance_band?(entry.amount, recurring.amount)
        return false unless recurring.schedule.matches_day?(entry.date)

        if recurring.merchant_id.present?
          entry.read_attribute("transaction_merchant_id") == recurring.merchant_id
        else
          entry.name == recurring.name
        end
      end

      # A recurring charge lands on the SAME day each month: every occurrence
      # must sit within the matching tolerance (2 days) of the expected day
      # on the circular calendar. Circular distance is what handles short
      # months -- a day-30 bill's February charge on the 28th is 2 away, in.
      #
      # This replaced a standard-deviation test that averaged the drift and
      # so accepted charges scattered across the 5th, 10th and 15th as one
      # "recurring" pattern. Consistency is per-occurrence, not on average,
      # and detection now agrees with the matcher about what "the same
      # occurrence" means.
      def days_cluster_together?(days)
        return false if days.empty?

        expected = calculate_expected_day(days)

        days.all? { |day| circular_distance(day, expected) <= Schedule::DAY_MATCH_TOLERANCE }
      end

      # Circular day distance is owned by Schedule; kept as a private alias
      # for the clustering math above.
      def circular_distance(day1, day2)
        Schedule.circular_day_distance(day1, day2)
      end

      # Calculate the expected day based on the most common day
      # Uses circular rotation to handle month-wrapping sequences (e.g., [29, 30, 31, 1, 2])
      def calculate_expected_day(days)
        return days.first if days.size == 1

        # Convert to 0-indexed (0-30 instead of 1-31) for modular arithmetic
        days_0 = days.map { |d| d - 1 }

        # Find the rotation (pivot) that minimizes span, making the cluster contiguous
        # This handles month-wrapping sequences like [29, 30, 31, 1, 2]
        best_pivot = 0
        min_span = Float::INFINITY

        (0..30).each do |pivot|
          rotated = days_0.map { |d| (d - pivot) % 31 }
          span = rotated.max - rotated.min

          if span < min_span
            min_span = span
            best_pivot = pivot
          end
        end

        # Rotate days using best pivot to create contiguous array
        rotated_days = days_0.map { |d| (d - best_pivot) % 31 }.sort

        # Calculate median on rotated, contiguous array
        mid = rotated_days.size / 2
        rotated_median = if rotated_days.size.odd?
          rotated_days[mid]
        else
          # For even count, average and round
          ((rotated_days[mid - 1] + rotated_days[mid]) / 2.0).round
        end

        # Map median back to original day space (unrotate) and convert to 1-indexed
        original_day = (rotated_median + best_pivot) % 31 + 1

        original_day
      end

      # Calculate next expected date. Date math is owned by Schedule.
      def calculate_next_expected_date(last_date, expected_day)
        Schedule.new(expected_day_of_month: expected_day).next_occurrence_after(last_date)
      end
  end
end

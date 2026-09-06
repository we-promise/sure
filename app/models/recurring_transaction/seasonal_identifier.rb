class RecurringTransaction
  # Detects obligations that recur on a cadence LONGER than a month: quarterly
  # tax instalments, an annual insurance premium, a yearly vehicle inspection,
  # a twice-yearly vet visit.
  #
  # Identifier cannot see any of these, and not by oversight: it looks back
  # 3 months, requires 3 occurrences, and tests consistency on the DAY OF THE
  # MONTH. Four quarterly instalments never produce three hits inside a
  # three-month window, so the pattern is structurally invisible and the money
  # is budgeted at zero. The failure is silent, which is the worst kind: nothing
  # reports that a whole class of obligation is missing.
  #
  # Deliberately a separate class rather than a branch inside Identifier. The
  # monthly pass is load-bearing and well tuned; this one answers a different
  # question (is the GAP between charges consistent, rather than is the day of
  # the month consistent) and gets to be wrong on its own.
  class SeasonalIdentifier
    LOOKBACK_MONTHS = 24

    # Two is the floor and also the ceiling for an annual charge: 24 months of
    # history cannot contain three. The safety valve is not the occurrence
    # count but the fact that everything lands as `suggested` and waits for the
    # user to confirm it.
    MIN_OCCURRENCES = 2

    # Higher than Identifier::MINIMUM_CANDIDATE_AMOUNT (1). Two loosely spaced
    # charges are much weaker evidence than three tightly spaced ones, so small
    # amounts are not worth the false positives they would bring.
    MINIMUM_AMOUNT = 25

    Cadence = Data.define(:preset, :days, :tolerance)

    # Tolerances are tight relative to the period. A quarterly bill drifts by a
    # few days around month lengths; anything looser starts matching unrelated
    # purchases that happen to fall a season apart.
    CADENCES = [
      Cadence.new(preset: "quarterly",  days: 91,  tolerance: 10),
      Cadence.new(preset: "semiannual", days: 182, tolerance: 15),
      Cadence.new(preset: "annual",     days: 365, tolerance: 25)
    ].freeze

    # Below this, the monthly pass owns the pattern. Without the guard both
    # passes would claim a monthly bill and the seasonal one would rewrite its
    # cadence.
    MIN_CADENCE_DAYS = 60

    attr_reader :family

    def initialize(family)
      @family = family
    end

    # Returns the series it created. Existing rows are never modified: a
    # cadence the user already declared, dismissed or ended stays exactly as it
    # is.
    def identify!
      created = []

      seasonal_patterns.each do |pattern|
        next if claimed?(pattern)

        series = create_suggested_series(pattern)
        created << series if series
      end

      created
    end

    # Read-only view for pickers and tests.
    def seasonal_patterns
      grouped_entries.filter_map do |(identifier, currency, account_id), entries|
        cluster = largest_consistent_cluster(entries)
        next if cluster.nil?

        dates = cluster.map(&:date).sort
        cadence = detect_cadence(dates)
        next if cadence.nil?
        next unless recent_enough?(dates.last, cadence)

        build_pattern(identifier, currency, account_id, cluster, dates, cadence)
      end
    end

    private
      def grouped_entries
        family.entries
              .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
              .where(entryable_type: "Transaction")
              .where("entries.date >= ?", LOOKBACK_MONTHS.months.ago.to_date)
              .where(entries: { excluded: false })
              .where("entries.amount > 0")
              .where.not("transactions.kind": Transaction::TRANSFER_KINDS)
              .includes(:entryable)
              .to_a
              .select { |entry| entry.entryable.is_a?(Transaction) }
              .group_by do |entry|
                [ identity_for(entry), entry.currency, entry.account_id ]
              end
      end

      # A merchant when one was detected, otherwise the CLEANED label. Grouping
      # on the raw name is what made this pass blind to exactly the charges it
      # exists to find: an annual premium arrives as "CB 02/09 AXA" one year and
      # "CB 04/09 AXA" the next, so every occurrence became its own one-row
      # group and none ever reached MIN_OCCURRENCES.
      def identity_for(entry)
        merchant_id = entry.entryable.merchant_id
        return [ :merchant, merchant_id ] if merchant_id.present?

        [ :name, Transaction::LabelNormalizer.normalize(entry.name, on: entry.date).name ]
      end

      # Same amount clustering as the monthly pass, then the biggest cluster
      # wins. A merchant billed both an annual premium and the odd small charge
      # should be read as the premium, not as an average of the two.
      def largest_consistent_cluster(entries)
        clusters = cluster_by_amount(entries).select do |cluster|
          cluster.size >= MIN_OCCURRENCES && (cluster.sum(&:amount) / cluster.size).abs >= MINIMUM_AMOUNT
        end

        clusters.max_by(&:size)
      end

      def cluster_by_amount(entries)
        clusters = []

        entries.sort_by(&:amount).each do |entry|
          current = clusters.last
          mean = current ? current.sum(&:amount) / current.size : nil

          if current && (entry.amount - mean).abs <= mean.abs * (Identifier::DEFAULT_TOLERANCE_PCT / 100.0)
            current << entry
          else
            clusters << [ entry ]
          end
        end

        clusters
      end

      # Consistency is judged per gap, not on the average, exactly as the
      # monthly pass judges it per occurrence. Charges 3, 6 and 15 months apart
      # average out to something plausible and are not a cadence.
      def detect_cadence(dates)
        gaps = dates.each_cons(2).map { |a, b| (b - a).to_i }
        return nil if gaps.empty?
        return nil if gaps.min < MIN_CADENCE_DAYS

        CADENCES.find do |cadence|
          gaps.all? { |gap| (gap - cadence.days).abs <= cadence.tolerance }
        end
      end

      # A cadence whose next charge is already well overdue is a cancelled
      # obligation, not a seasonal one.
      def recent_enough?(last_date, cadence)
        last_date >= (Date.current - (cadence.days * 1.25).to_i)
      end

      def build_pattern(identifier, currency, account_id, cluster, dates, cadence)
        amounts = cluster.map(&:amount)
        identifier_type, identifier_value = identifier
        last_entry = cluster.max_by(&:date)

        {
          name: identifier_type == :name ? identifier_value : nil,
          merchant_id: identifier_type == :merchant ? identifier_value : nil,
          currency: currency,
          account_id: account_id,
          amount: last_entry.amount,
          expected_amount_min: amounts.min,
          expected_amount_max: amounts.max,
          expected_amount_avg: amounts.sum / amounts.size,
          occurrence_count: cluster.size,
          last_occurrence_date: dates.last,
          cadence: cadence,
          entries: cluster
        }
      end

      # Claimed by identity alone, amount ignored. A seasonal charge drifts far
      # more between years than a monthly one does between months (indexation,
      # rate changes), so amount-nearness would fail to recognise the user's own
      # declared series and duplicate it.
      def claimed?(pattern)
        family.recurring_transactions.any? do |recurring|
          next false unless recurring.currency == pattern[:currency]
          next false if recurring.account_id.present? && recurring.account_id != pattern[:account_id]

          if pattern[:merchant_id].present?
            recurring.merchant_id == pattern[:merchant_id]
          else
            recurring.merchant_id.nil? && recurring.name == pattern[:name]
          end
        end
      end

      def create_suggested_series(pattern)
        cadence = pattern[:cadence]
        last_date = pattern[:last_occurrence_date]
        account = pattern[:account_id] && Account.find_by(id: pattern[:account_id])
        classification = Classifier.classify(
          name: pattern[:name] || pattern[:entries].first.name,
          entries: pattern[:entries],
          account: account
        )

        series = family.recurring_transactions.new(
          currency: pattern[:currency],
          account_id: pattern[:account_id],
          merchant_id: pattern[:merchant_id],
          name: pattern[:merchant_id].present? ? nil : pattern[:name],
          amount: pattern[:amount],
          expected_amount_min: pattern[:expected_amount_min],
          expected_amount_max: pattern[:expected_amount_max],
          expected_amount_avg: pattern[:expected_amount_avg],
          expected_day_of_month: last_date.day,
          last_occurrence_date: last_date,
          # Overwritten by the schedule below; the column is NOT NULL so it
          # needs a value before the record is valid.
          next_expected_date: last_date,
          occurrence_count: pattern[:occurrence_count],
          anchor_date: last_date,
          status: "suggested",
          bill_type: classification.bill_type,
          category_id: classification.category_id,
          autopay: classification.autopay,
          manual: false
        )

        # Reusing FrequencyPreset rather than hand-building rules: it owns the
        # anchor_date requirement for interval > 1 and the expected_day_of_month
        # bookkeeping, and an interval rule without an anchor raises from
        # Schedule#initialize.
        FrequencyPreset.apply(
          series,
          preset: cadence.preset,
          day_of_month: last_date.day,
          month_of_year: cadence.preset == "annual" ? last_date.month : nil
        )

        series.next_expected_date = series.schedule.next_occurrence_after(last_date) || last_date
        series.save!
        series
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        # Raced by another run, or the identity collides with a row this pass
        # did not see. Never worth failing the whole detection for.
        nil
      end
  end
end

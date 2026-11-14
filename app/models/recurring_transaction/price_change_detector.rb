class RecurringTransaction
  # Notices when a bill's real charges settle on a new price and keeps the
  # series honest about it. Two consecutive paid occurrences, each settled by
  # a single payment, agreeing on an amount different from the series' --
  # that is a price change, not noise. One odd charge is never enough.
  #
  # Auto-detected series get their amount updated (detection created them,
  # detection maintains them); manually declared series only get the price
  # change RECORDED -- the user stated that amount, so the user changes it,
  # with the recorded change surfacing the suggestion.
  class PriceChangeDetector
    EPSILON = BigDecimal("0.01")

    attr_reader :family

    def initialize(family)
      @family = family
    end

    RECENT_LIMIT = 2

    def detect!
      changes = 0

      # Load each batch's recent paid occurrences (and their allocations) in
      # one query instead of one per series, which was an N+1.
      family.recurring_transactions.active.where("amount > 0").find_in_batches do |batch|
        recent_by_series = recent_paid_occurrences_for(batch.map(&:id))

        batch.each do |series|
          changes += 1 if detect_for(series, recent_by_series.fetch(series.id, []))
        end
      end

      changes
    end

    private
      # The latest RECENT_LIMIT paid occurrences per series, newest first,
      # grouped by series id. `id DESC` breaks same-day ties deterministically.
      def recent_paid_occurrences_for(series_ids)
        return {} if series_ids.empty?

        ranked = RecurringOccurrence
                   .paid
                   .where(recurring_transaction_id: series_ids)
                   .select(
                     "recurring_occurrences.*",
                     "ROW_NUMBER() OVER (PARTITION BY recurring_occurrences.recurring_transaction_id " \
                     "ORDER BY recurring_occurrences.due_on DESC, recurring_occurrences.id DESC) AS recency_rank"
                   )

        RecurringOccurrence
          .from(ranked, :recurring_occurrences)
          .where("recurring_occurrences.recency_rank <= ?", RECENT_LIMIT)
          .order(:recurring_transaction_id, due_on: :desc, id: :desc)
          .includes(:allocations)
          .to_a
          .group_by(&:recurring_transaction_id)
      end

      def detect_for(series, recent)
        return false unless recent.size == RECENT_LIMIT

        settlements = recent.map do |occurrence|
          confirmed = occurrence.allocations.select(&:allocation_confirmed?)
          # Only single-payment settlements speak to the PRICE; a pile of
          # partials says nothing about what the biller charges.
          confirmed.size == 1 ? confirmed.first : nil
        end
        return false if settlements.any?(&:nil?)

        totals = settlements.map(&:allocated_amount)
        return false unless (totals.first - totals.last).abs <= EPSILON

        new_amount = totals.first
        return false if (new_amount - series.amount.abs).abs <= EPSILON

        effective_on = recent.first.due_on
        return false if series.recurring_price_changes.exists?(effective_on: effective_on)
        return false if series.recurring_price_changes.order(:effective_on).last&.new_amount == new_amount

        RecurringPriceChange.create!(
          recurring_transaction: series,
          effective_on: effective_on,
          previous_amount: series.amount.abs,
          new_amount: new_amount,
          currency: series.currency,
          source: "detected",
          entry: settlements.first.entry
        )

        series.update!(amount: new_amount) unless series.manual?

        true
      rescue ActiveRecord::RecordNotUnique
        false
      end
  end
end

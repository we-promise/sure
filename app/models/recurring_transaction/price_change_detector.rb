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

    def detect!
      changes = 0

      family.recurring_transactions.active.where("amount > 0").find_each do |series|
        changes += 1 if detect_for(series)
      end

      changes
    end

    private
      def detect_for(series)
        recent = series.recurring_occurrences
                       .paid
                       .order(due_on: :desc)
                       .limit(2)
                       .includes(:allocations)
                       .to_a
        return false unless recent.size == 2

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

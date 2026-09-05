# Nightly sweep keeping every family's occurrence window materialized (the
# sync-triggered pipeline covers synced families; this catches manual-only
# families that never sync). Runs before GenerateInsightsJob so generators
# see fresh occurrences.
class GenerateRecurringOccurrencesJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform(family_id = nil)
    if family_id.nil?
      fan_out
    else
      generate_for_family(family_id)
    end
  end

  private
    def fan_out
      Family.find_each do |family|
        next if family.recurring_transactions_disabled?

        self.class.perform_later(family.id)
      end
    end

    def generate_for_family(family_id)
      family = Family.find_by(id: family_id)
      return unless family
      return if family.recurring_transactions_disabled?

      # Shares the pipeline's per-family lock so the nightly sweep and the
      # sync-triggered pipeline serialize against each other.
      RecurringTransaction::Pipeline.with_family_lock(family_id) do
        # Nightly is where the seasonal pass belongs: it reads 24 months of
        # entries, which is too heavy for the debounced post-sync pipeline, and
        # a quarterly or annual charge cannot appear between two syncs.
        # Occurrences are generated after it so a series detected tonight is
        # materialized tonight rather than a day later.
        RecurringTransaction::SeasonalIdentifier.new(family).identify!

        family.recurring_transactions.active.find_each do |series|
          RecurringTransaction::OccurrenceGenerator.new(series).generate!
        end
      end
    end
end

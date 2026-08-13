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

      with_advisory_lock(family_id) do
        family.recurring_transactions.active.find_each do |series|
          RecurringTransaction::OccurrenceGenerator.new(series).generate!
        end
      end
    end

    def with_advisory_lock(family_id)
      lock_key = advisory_lock_key(family_id)
      acquired = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_lock(?)", lock_key ])
      )

      return unless acquired

      begin
        yield
      ensure
        ActiveRecord::Base.connection.execute(
          ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_unlock(?)", lock_key ])
        )
      end
    end

    # Same key derivation as IdentifyRecurringTransactionsJob so the nightly
    # sweep and the sync-triggered pipeline serialize against each other.
    def advisory_lock_key(family_id)
      Digest::MD5.hexdigest("recurring_transaction_identify:#{family_id}").to_i(16) % (2**31)
    end
end

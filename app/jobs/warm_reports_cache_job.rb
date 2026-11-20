# Builds the Reports views each member most often opens, so they are cached
# before anyone asks. Enqueued after a family sync, late enough for the rules
# that sync starts to have run: a body built before a rule recategorises
# entries would be keyed on stale data and never served.
class WarmReportsCacheJob < ApplicationJob
  queue_as :low_priority

  AFTER_SYNC_DELAY = 5.minutes

  def perform(family)
    family.users.find_each do |user|
      ReportsController::WARMED_PERIOD_TYPES.each do |period_type|
        ReportsController.warm_body_cache(user: user, query: { period_type: period_type })
      rescue StandardError => e
        # One view failing to build leaves it to be built when opened; the rest still warm.
        Rails.logger.warn("[WarmReportsCacheJob] #{period_type} for user #{user.id} failed: #{e.class}: #{e.message}")
      end
    end
  end
end

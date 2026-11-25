# Builds the Reports views each member most often opens, so they are cached
# before anyone asks. ApplyRulesJob enqueues it after a family sync, once the
# sync's rules have run.
class WarmReportsCacheJob < ApplicationJob
  queue_as :low_priority

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

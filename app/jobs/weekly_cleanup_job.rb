# Weekly proactive cleanup: runs the read-only WeeklyCleanup detectors per
# family and opens one proactive chat per admin with the findings.
#
# Mirrors GenerateInsightsJob's shape: cron entry fans out one job per
# preview-enabled family, each family run is re-gated and advisory-locked, and
# the per-admin chat creation is idempotent via WeeklyCleanupRun.
class WeeklyCleanupJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  # Without args (cron): fans out one job per family.
  # With family_id: generates this family's cleanup chats.
  def perform(family_id: nil)
    if family_id.present?
      generate_for_family(family_id)
    else
      fan_out
    end
  end

  private
    def fan_out
      Family.with_preview_features.find_each do |family|
        WeeklyCleanupJob.perform_later(family_id: family.id)
      rescue => e
        Rails.logger.error("Failed to enqueue weekly cleanup for family #{family.id}: #{e.message}")
      end
    end

    def generate_for_family(family_id)
      family = Family.find_by(id: family_id)
      return unless family
      return if family.accounts.none?
      # Re-gated here, not just at fan-out: this path is reachable directly via
      # perform_later(family_id:).
      return unless family.preview_features_enabled?

      with_advisory_lock(family_id) do
        I18n.with_locale(family.locale) do
          WeeklyCleanup::ChatCreator.call(family:)
        end
      end
    end

    def with_advisory_lock(family_id)
      lock_key = advisory_lock_key(family_id)
      acquired = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_lock(?)", lock_key ])
      )

      unless acquired
        Rails.logger.warn("Skipped weekly cleanup for family #{family_id}: advisory lock unavailable")
        return
      end

      begin
        yield
      ensure
        ActiveRecord::Base.connection.execute(
          ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_unlock(?)", lock_key ])
        )
      end
    end

    def advisory_lock_key(family_id)
      Digest::MD5.hexdigest("weekly_cleanup:#{family_id}").to_i(16) % (2**62)
    end
end

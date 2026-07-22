class SyncCleanerJob < ApplicationJob
  queue_as :scheduled

  # Provider account rows flip activities_fetch_pending while a fetch-job chain
  # runs; the chain's state lives only in job args, so a lost link strands the
  # flag (and its "fetching" UI badge) forever.
  ACTIVITY_FLAG_STUCK_AFTER = 6.hours
  ACTIVITY_FLAG_MODELS = %w[SnaptradeAccount QuestradeAccount IndexaCapitalAccount].freeze

  # Sweeps records whose background job died without finalizing them. A hard
  # worker kill (OOM, SIGKILL during deploy) loses in-flight Sidekiq jobs
  # permanently, leaving records wedged in non-terminal statuses. Each sweep is
  # isolated so one failing model doesn't block the others.
  def perform
    sweep("syncs") { Sync.clean }
    sweep("imports") { Import.clean }
    sweep("import_sessions") { ImportSession.clean }
    sweep("family_exports") { FamilyExport.clean }
    sweep("pdf_imports") { PdfImport.clean }
    sweep("provider_activity_flags") { clear_stuck_activity_fetch_flags }
  end

  private
    def sweep(label)
      yield
    rescue => e
      Rails.logger.error("SyncCleanerJob sweep #{label} failed: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) do |scope|
        scope.set_tags(sweep: label)
      end
    end

    def clear_stuck_activity_fetch_flags
      ACTIVITY_FLAG_MODELS.each do |model_name|
        model = model_name.constantize
        scope = model.where(activities_fetch_pending: true)
                     .where("updated_at < ?", ACTIVITY_FLAG_STUCK_AFTER.ago)
        scope = scope.includes(:account) if model.reflect_on_association(:account)
        scope.find_each do |record|
          # Read before the lock — see Import.reap_stuck!.
          account = record.respond_to?(:account) ? record.account : nil

          # Row-lock + re-check so a fetch chain finishing right now isn't
          # clobbered mid-write (same guard as the reapers, see #2680).
          record.with_lock do
            next unless record.activities_fetch_pending? && record.updated_at < ACTIVITY_FLAG_STUCK_AFTER.ago

            record.update!(activities_fetch_pending: false)

            DebugLogEntry.capture(
              category: "background_jobs",
              level: "warn",
              message: "Cleared #{model_name} activities_fetch_pending flag stuck for over #{ACTIVITY_FLAG_STUCK_AFTER.inspect}",
              source: self.class.name,
              account: account,
              metadata: { record_type: model_name, record_id: record.id }
            )
          end
        rescue => e
          # One bad record must not abort the sweep for the rest of this
          # model or the models still to come.
          Rails.logger.error("SyncCleanerJob activity-flag sweep failed for #{model_name} #{record.id}: #{e.class}: #{e.message}")
          Sentry.capture_exception(e) { |scope| scope.set_tags(record_type: model_name, record_id: record.id) } if defined?(Sentry)
        end
      end
    end
end

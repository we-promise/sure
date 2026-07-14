# frozen_string_literal: true

class Settings::BackgroundJobsController < Admin::BaseController
  CANCELLABLE_TYPES = {
    "Sync" => Sync,
    "Import" => Import,
    "ImportSession" => ImportSession,
    "FamilyExport" => FamilyExport
  }.freeze

  CANCELLED_ERROR = "Marked as failed by an administrator — the background job was presumed lost.".freeze

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("settings.background_jobs.show.page_title"), nil ]
    ]

    @console = BackgroundJobConsole.new
    @operations = @console.operations
  end

  def cancel
    record = find_record!
    console = BackgroundJobConsole.new

    # Server-side re-check — the button state in the UI is not trusted. The
    # with_lock block re-reads the record, so a job finishing between render
    # and click cannot be clobbered (it already moved the status on).
    cancelled = console.cancellable?(record) && record.with_lock do
      if cancellable_status?(record)
        prior_status = record.status
        apply_cancel!(record)
        audit_cancel!(record, prior_status)
        true
      else
        false
      end
    end

    if cancelled
      redirect_to settings_background_jobs_path, notice: t(".cancelled", type: record.class.name)
    else
      redirect_to settings_background_jobs_path, alert: t(".not_cancellable")
    end
  end

  private
    def find_record!
      model = CANCELLABLE_TYPES.fetch(params[:record_type]) do
        raise ActiveRecord::RecordNotFound, "Unknown record type"
      end

      model.find(params[:id])
    end

    def cancellable_status?(record)
      case record
      when Sync then record.in_progress?
      when Import then record.importing? || record.reverting?
      when ImportSession then record.importing?
      when FamilyExport then record.pending? || record.processing?
      end
    end

    def apply_cancel!(record)
      case record
      when Sync
        record.mark_stale!
      when PdfImport
        # A PdfImport's importing status is a processing claim — release it so
        # the user can re-trigger, mirroring ProcessPdfJob's own reclaim.
        record.update!(status: :pending)
      when Import
        record.update!(
          status: record.reverting? ? :revert_failed : :failed,
          error: CANCELLED_ERROR
        )
      when ImportSession
        record.update!(
          status: :failed,
          error_details: { "code" => "cancelled_by_admin", "message" => CANCELLED_ERROR }
        )
      when FamilyExport
        record.update!(status: :failed)
      end
    end

    def audit_cancel!(record, prior_status)
      DebugLogEntry.capture(
        category: "background_jobs",
        level: "warn",
        message: "#{record.class.name} #{record.id} marked as lost from the background jobs console (was #{prior_status})",
        source: self.class.name,
        family: BackgroundJobConsole.family_for(record),
        metadata: {
          record_type: record.class.name,
          record_id: record.id,
          previous_status: prior_status,
          new_status: record.status,
          actor_user_id: Current.user.id
        }
      )
    end
end

# frozen_string_literal: true

class Settings::BackgroundJobsController < Admin::BaseController
  CANCELLABLE_BASE_TYPES = [ Sync, Import, ImportSession, FamilyExport ].freeze

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
    # and click cannot be clobbered (it already moved the status on). The
    # stuck-window check repeats inside the lock too: cancellable? evaluated
    # Sidekiq liveness outside the transaction (re-running Redis calls under
    # a row lock would be worse), so a worker that grabbed the job in between
    # shows up here as a freshly-touched updated_at.
    cancelled = console.cancellable?(record) && record.with_lock do
      if cancellable_status?(record) && record.updated_at <= BackgroundJobConsole::STUCK_AFTER.ago
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
    # Resolves record_type against the cancellable base classes, accepting
    # STI subclass names too (the UI sends base_class names, but a direct
    # request naming e.g. TransactionImport shouldn't 404). safe_constantize
    # only resolves already-defined constants and the `<=` whitelist check
    # rejects anything outside the cancellable hierarchy.
    def find_record!
      model = params[:record_type].to_s.match?(/\A[A-Za-z]+\z/) ? params[:record_type].safe_constantize : nil

      unless model.is_a?(Class) && CANCELLABLE_BASE_TYPES.any? { |base| model <= base }
        raise ActiveRecord::RecordNotFound, "Unknown record type"
      end

      model.find(params[:id])
    end

    # User-facing: surfaces as the failed operation's error in the family UI.
    def cancelled_error_message
      t("settings.background_jobs.cancel.cancelled_error")
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
        if record.reverting?
          # A stuck revert may have half-deleted entries — pending would
          # present the import as publishable again. Route it through the
          # same revert_failed retry path as every other import.
          record.update!(status: :revert_failed, error: cancelled_error_message)
        else
          # importing is the AI-processing claim — release it so the user
          # can re-trigger, mirroring ProcessPdfJob's own reclaim.
          record.update!(status: :pending)
        end
      when Import
        record.update!(
          status: record.reverting? ? :revert_failed : :failed,
          error: cancelled_error_message
        )
      when ImportSession
        record.update!(
          status: :failed,
          error_details: { "code" => "cancelled_by_admin", "message" => cancelled_error_message }
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

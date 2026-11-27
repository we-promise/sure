# Renders the add-bill dialog with a waiting frame; the job's broadcast points
# it at #show, which renders the stored answer in a normal request with a fresh
# authenticity token. Inherits the parent so the dialog's partials resolve.
class RecurringTransactions::SmartFillsController < RecurringTransactionsController
  include AiFeatureGuard
  include RecurringFeatureGuardable

  # The parent's destroy callback loads a bill by params[:id]; here that id names
  # a suggestion, so Stop must not go through it.
  skip_before_action :set_recurring_transaction, only: :destroy
  skip_before_action :ensure_series_writable, only: :destroy

  before_action :ensure_recurring_enabled
  # Only starting a request needs the feature; show and Stop read or cancel a
  # stored suggestion and must stay reachable if availability changes later.
  requires_ai :bill_setup, only: :create
  before_action :prepare_form, only: %i[show destroy]

  # One request per pending suggestion: a second click reuses the row instead
  # of queueing another job for the same entry.
  def create
    income = params[:income].present?
    entry = Current.accessible_entries.find_by(id: params[:entry_id])
    return render_missing_entry(income:) if entry.nil?

    @suggestion = pending_suggestion(entry:, income:)

    enqueue_job if @suggestion.previously_new_record?
    prepare_form(entry:, income:)
    render "recurring_transactions/new", layout: dialog_layout
  end

  def show
    respond_to do |format|
      # The waiting frame probes status so it can navigate only once the answer is
      # final; it never reads the stored proposal from this response.
      format.json { render json: { status: @suggestion.status } }
      format.html { render layout: dialog_layout }
    end
  end

  # Stop is cooperative: the row is marked, never a request interrupted. A
  # finished suggestion has no Stop button, but a stale one just reloads show.
  def destroy
    if @suggestion.pending?
      @suggestion.with_lock { @suggestion.update!(status: :cancelled) if @suggestion.pending? }
      render :show, layout: dialog_layout
    else
      redirect_to @suggestion.location, status: :see_other
    end
  end

  private
    def suggestion
      @suggestion ||= Current.family.recurring_transaction_suggestions
                              .where(user: Current.user, mode: :fill).find(params[:id])
    end

    def pending_suggestion(entry:, income:)
      # Two clicks can arrive together; the entry lock keeps the second one
      # behind the first insert. The unique index is the backstop if a row is
      # inserted by another path, in which case reuse it without a second job.
      # Entry#transaction is the delegated-type accessor, so with_lock cannot be
      # used here: the explicit class-level transaction is the one that locks.
      Entry.transaction do
        entry.lock!
        Current.family.recurring_transaction_suggestions.find_or_create_by!(
          user: Current.user, entry:, income:, mode: :fill, status: :pending
        )
      end
    rescue ActiveRecord::RecordNotUnique
      Current.family.recurring_transaction_suggestions.find_by!(
        user: Current.user, entry:, income:, mode: :fill, status: :pending
      )
    end

    def prepare_form(entry: nil, income: nil)
      @suggestion ||= suggestion
      # Access can be revoked after the request was queued. Stop and show must
      # not prefill from an entry the requester can no longer read.
      entry ||= Current.accessible_entries.find_by(id: @suggestion.entry_id)
      entry_revoked = @suggestion.fill? && @suggestion.entry_id.present? && entry.nil?
      income = @suggestion.income if income.nil?

      @recurring_transaction = Current.family.recurring_transactions.new(
        frequency_preset: income ? "biweekly" : "monthly",
        first_due_on: Date.current,
        currency: Current.family.currency
      )
      @recurring_transaction.is_income = income
      @source_entry = entry
      @covering_series = covering_series_for(entry) if entry
      prefill_recurring_from_entry(entry) if entry
      # The answer belongs to evidence this user can no longer read: neither its values nor its
      # rationale may reach the form. Stop stays available while the suggestion is pending.
      @entry_access_revoked = entry_revoked
      @suggestion.apply_to(@recurring_transaction) unless entry_revoked
    end

    def render_missing_entry(income:)
      @recurring_transaction = Current.family.recurring_transactions.new(
        frequency_preset: income ? "biweekly" : "monthly",
        first_due_on: Date.current,
        currency: Current.family.currency
      )
      @recurring_transaction.is_income = income
      @smart_fill_error = t(".failed")
      render "recurring_transactions/new", layout: dialog_layout
    end

    def enqueue_job
      Ai::GenerationRun.enqueue(:bill_setup, family: Current.family, ids: [ @suggestion.id ], id: @suggestion.id)
    rescue StandardError => error
      Rails.error.report(error, handled: true, context: { feature: "bill_setup" })
      @suggestion.update!(status: :failed, error: "generation_failed")
    end
end

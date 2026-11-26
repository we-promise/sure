# Proposes configuration corrections for one bill. #show renders the stored
# answer; its form PATCHes the ordinary update action, so applying keeps every
# check that path already makes.
class Bills::SmartConfigurationsController < ApplicationController
  include AiFeatureGuard
  include RecurringFeatureGuardable

  before_action :ensure_recurring_enabled
  # Only starting a request needs the feature; show and Stop read or cancel a
  # stored suggestion and must stay reachable if availability changes later.
  requires_ai :bill_setup, only: :create
  before_action :set_suggestion, :set_series, only: %i[show destroy]

  def create
    @series = Current.family.recurring_transactions.accessible_by(Current.user).find(params[:bill_id])
    @detection = RecurringTransaction::FrequencyPreset.detect(@series)

    @suggestion = pending_suggestion(@series)

    enqueue_job if @suggestion.previously_new_record?
    render layout: dialog_layout
  end

  def show
    render layout: dialog_layout
  end

  # A Stop that races a finished answer changes nothing; the browser reloads
  # show instead, which now holds the result.
  def destroy
    if @suggestion.pending?
      @suggestion.with_lock { @suggestion.update!(status: :cancelled) if @suggestion.pending? }
      render :show, layout: dialog_layout
    else
      redirect_to @suggestion.location, status: :see_other
    end
  end

  private
    def pending_suggestion(series)
      # Two clicks can arrive together; the bill lock keeps the second one
      # behind the first insert. The unique index is the backstop if another
      # path inserted the row first, in which case reuse it without a new job.
      series.with_lock do
        Current.family.recurring_transaction_suggestions.find_or_create_by!(
          user: Current.user, recurring_transaction: series, mode: :configure, status: :pending
        )
      end
    rescue ActiveRecord::RecordNotUnique
      Current.family.recurring_transaction_suggestions.find_by!(
        user: Current.user, recurring_transaction: series, mode: :configure, status: :pending
      )
    end

    def set_suggestion
      @suggestion ||= Current.family.recurring_transaction_suggestions
                              .where(user: Current.user, mode: :configure, recurring_transaction_id: params[:bill_id])
                              .find(params[:id])
    end

    def set_series
      @series = Current.family.recurring_transactions.accessible_by(Current.user).find(@suggestion.recurring_transaction_id)
      @detection = RecurringTransaction::FrequencyPreset.detect(@series)
    end

    def enqueue_job
      Ai::GenerationRun.enqueue(:bill_setup, family: Current.family, ids: [ @suggestion.id ], id: @suggestion.id)
    rescue StandardError => error
      Rails.error.report(error, handled: true, context: { feature: "bill_setup" })
      @suggestion.update!(status: :failed, error: "generation_failed")
    end
end

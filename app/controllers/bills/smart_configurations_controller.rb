class Bills::SmartConfigurationsController < ApplicationController
  include BillsHelper
  include RecurringFeatureGuardable

  guard_feature unless: -> { bills_one_shot_ai_available? }
  before_action :ensure_recurring_enabled

  # Proposes configuration corrections for one bill from its own charge
  # history (configure mode: only fields the history contradicts come back).
  # The dialog's form PATCHes the ordinary recurring_transactions#update, so
  # applying inherits every rule that path already enforces -- sign and
  # ownership handling, preset application, schedule pinning, occurrence
  # regeneration. Nothing applies without the user checking it.
  def show
    @series = Current.family.recurring_transactions
                     .accessible_by(Current.user)
                     .includes(:merchant, :category)
                     .find(params[:id])

    begin
      @suggestion = RecurringTransaction::AiSetupSuggester
                      .new(Current.family, user: Current.user)
                      .suggest_configuration(@series)
      @detection = RecurringTransaction::FrequencyPreset.detect(@series)
    rescue RecurringTransaction::AiSetupSuggester::Error => e
      Rails.logger.warn("Smart configure failed for series #{@series.id}: #{e.class}: #{e.message}")
      @error = t(".failed")
    end

    render layout: dialog_layout
  end
end

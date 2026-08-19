# Shared guards for the Bills / recurring-transactions surfaces: every
# controller in the subsystem bails to the home page when the family has
# switched the feature off, and the dialog surfaces drop the layout for
# turbo-frame requests so the shared modal frame stays unique in the response.
module RecurringFeatureGuardable
  extend ActiveSupport::Concern

  private
    def ensure_recurring_enabled
      redirect_to root_path if Current.family.recurring_transactions_disabled?
    end

    def dialog_layout
      turbo_frame_request? ? false : "settings"
    end
end

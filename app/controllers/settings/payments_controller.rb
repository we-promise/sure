class Settings::PaymentsController < ApplicationController
  layout "settings"

  guard_feature unless: -> { Current.family.can_manage_subscription? }

  def show
    @family = Current.family
  end
end

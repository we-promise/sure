class Settings::PaymentsController < ApplicationController
  layout "settings"

  guard_feature unless: -> { Current.family.can_manage_subscription? }

  def show
    @family = Current.family
    @one_time_contribution_url = stripe&.one_time_contribution_url
  end

  private
    def stripe
      @stripe ||= Provider::Registry.get_provider(:stripe)
    end
end

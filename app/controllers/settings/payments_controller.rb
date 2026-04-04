class Settings::PaymentsController < ApplicationController
  layout "settings"

  guard_feature unless: -> { Current.family.can_manage_subscription? }

  def show
    @family = Current.family
    @one_time_contribution_url = stripe&.payment_link_url(payment_link_id:) if payment_link_id.present?
  end

  private
    def payment_link_id
      ENV["STRIPE_PAYMENT_LINK_ID"]
    end

    def stripe
      @stripe ||= Provider::Registry.get_provider(:stripe)
    end
end

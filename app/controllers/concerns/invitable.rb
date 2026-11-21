module Invitable
  extend ActiveSupport::Concern

  included do
    helper_method :invite_code_required?, :signup_closed?
  end

  private
    def signup_closed?
      self_hosted? && Setting.onboarding_state == "closed"
    end

    def invite_code_required?
      return false if @invitation.present?
      if self_hosted?
        Setting.onboarding_state == "invite_only" && Setting.invite_only_default_family_id.blank?
      else
        ENV["REQUIRE_INVITE_CODE"] == "true"
      end
    end

    def self_hosted?
      Rails.application.config.app_mode.self_hosted?
    end
end

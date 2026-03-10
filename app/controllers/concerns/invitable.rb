module Invitable
  extend ActiveSupport::Concern

  included do
    helper_method :invite_code_required? if respond_to?(:helper_method)
  end

  private
    def invite_code_required?
      return false if @invitation.present?
      if self_hosted?
        Setting.onboarding_state == "invite_only" && Setting.invite_only_default_family_id.blank?
      else
        ENV["REQUIRE_INVITE_CODE"] == "true"
      end
    end

    def assign_invite_only_default_family(user)
      return false unless Setting.onboarding_state == "invite_only"

      default_family_id = Setting.invite_only_default_family_id
      return false if default_family_id.blank?

      default_family = Family.find_by(id: default_family_id)
      return false if default_family.nil?

      user.family = default_family
      user.role = :member
      true
    end

    def self_hosted?
      Rails.application.config.app_mode.self_hosted?
    end
end

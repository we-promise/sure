module DemoMfaRestriction
  extend ActiveSupport::Concern

  included do
    helper_method :demo_family_mfa_restricted?
  end

  private
    def demo_family_mfa_restricted?
      # Include the deployment domain so an alternate host cannot bypass the
      # restriction on a sure.am installation. Do not match lookalike domains.
      sure_domain = [ request.host, ENV["APP_DOMAIN"] ].compact.any? do |value|
        host = value.downcase.delete_suffix(".")
        host == "sure.am" || host.end_with?(".sure.am")
      end
      return false unless sure_domain && Current.family

      email = Rails.application.config_for(:demo).fetch(:email)
      email.present? && Current.family.users.exists?(email: email)
    end

    def require_mfa_enrollment_allowed
      return unless demo_family_mfa_restricted?

      respond_to do |format|
        format.html { redirect_to settings_security_path, alert: t("mfa.demo_family_restricted") }
        format.json { render json: { error: t("mfa.demo_family_restricted") }, status: :forbidden }
        format.any { head :forbidden }
      end
    end
end

# SAFETY: Only operates in development/test environments to prevent data loss
class Demo::DataCleaner
  SAFE_ENVIRONMENTS = %w[development test]

  def initialize
    ensure_safe_environment!
  end

  # Main entry point for destroying all demo data
  def destroy_everything!
    # Clear SSO audit logs first (they reference users)
    SsoAuditLog.destroy_all

    # ApiKey#prevent_demo_monitoring_key_destroy! throws :abort to stop the demo
    # monitoring key being revoked from the UI. That abort silently no-ops the
    # entire Family.destroy_all cascade below (accounts/entries/trades all
    # survive), which only then surfaces as a NOT NULL crash in
    # `Security.destroy_all`. Safe to bypass here: this class only runs in
    # dev/test (see #ensure_safe_environment!).

    ApiKey.where(display_key: ApiKey::DEMO_MONITORING_KEY).delete_all

    Family.destroy_all
    Setting.destroy_all
    InviteCode.destroy_all
    ExchangeRate.destroy_all
    Security.destroy_all
    Security::Price.destroy_all

    puts "Data cleared"
  end

  private

    def ensure_safe_environment!
      unless SAFE_ENVIRONMENTS.include?(Rails.env)
        raise SecurityError, "Demo::DataCleaner can only be used in #{SAFE_ENVIRONMENTS.join(', ')} environments. Current: #{Rails.env}"
      end
    end
end

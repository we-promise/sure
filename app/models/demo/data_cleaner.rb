# SAFETY: Only operates in development/test environments to prevent data loss
class Demo::DataCleaner
  SAFE_ENVIRONMENTS = %w[development test]

  def initialize
    ensure_safe_environment!
  end

  # Main entry point for destroying all demo data
  def destroy_everything!(force: false)
    ensure_safety_checks!(force)

    # Clear SSO audit logs first (they reference users)
    SsoAuditLog.destroy_all

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

    def ensure_safety_checks!(force)
      ensure_safe_environment!

      return if force || ENV["FORCE_DEMO_RESET"] == "true"
      return if User.count.zero?

      raise SecurityError, <<~MSG
        ⚠️  ABORTING: Existing users found in database!

        Running this task will DELETE ALL ACCOUNTS and data.
        To proceed, you must explicitly allow this:

        1. Run with force argument: destroy_everything!(force: true)
        2. Or set environment variable: FORCE_DEMO_RESET=true rake demo_data:default
      MSG
    end
end

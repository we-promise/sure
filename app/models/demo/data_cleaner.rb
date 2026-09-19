# SAFETY: Only operates in development/test environments to prevent data loss
class Demo::DataCleaner
  SAFE_ENVIRONMENTS = %w[development test]

  def initialize
    ensure_safe_environment!
  end

  # Main entry point for destroying all demo data.
  #
  # All or nothing. Family.destroy_all used to skip any family whose
  # before_destroy aborted without saying so, and the settings, invite codes
  # and exchange rates after it were wiped regardless. The half-cleared
  # database then crashed on Security.destroy_all (trades still pointing at
  # securities), and the generator could not recreate the demo users because
  # their emails were still taken.
  def destroy_everything!
    ActiveRecord::Base.transaction do
      # Clear SSO audit logs first (they reference users)
      SsoAuditLog.destroy_all

      # Rows whose foreign key blocks the cascade below and that no
      # association removes: unlinked provider merchants (DataCleanerJob only
      # drops them after 30 days) and the request logs of impersonation
      # sessions.
      FamilyMerchantAssociation.delete_all
      ImpersonationSessionLog.delete_all

      disarm_destroy_guards!

      Family.find_each do |family|
        family.destroy!
      rescue ActiveRecord::RecordNotDestroyed => e
        # Name the guard, not just the record: "Failed to destroy User" alone
        # does not say which callback aborted.
        reasons = e.record&.errors&.full_messages&.to_sentence.presence || "a before_destroy callback aborted"
        raise ActiveRecord::RecordNotDestroyed.new("#{e.message} (#{reasons})", e.record)
      end

      Setting.destroy_all
      InviteCode.destroy_all
      ExchangeRate.destroy_all
      Security.destroy_all
      Security::Price.destroy_all
    end

    puts "Data cleared"
  end

  private

    def ensure_safe_environment!
      unless SAFE_ENVIRONMENTS.include?(Rails.env)
        raise SecurityError, "Demo::DataCleaner can only be used in #{SAFE_ENVIRONMENTS.join(', ')} environments. Current: #{Rails.env}"
      end
    end

    # Guards that protect real data from the UI and have nothing to protect
    # here. Each one aborts the destroy of a record the reset must remove.
    # Safe to bypass: this class only runs in dev/test (see
    # #ensure_safe_environment!).
    def disarm_destroy_guards!
      # ApiKey#prevent_demo_monitoring_key_destroy! stops the demo monitoring
      # key being revoked from the UI.
      ApiKey.where(display_key: ApiKey::DEMO_MONITORING_KEY).delete_all

      # A family cancels its Stripe subscription before it goes, and aborts
      # when Stripe refuses. The demo family's is fake ("sub_demo_123"), so the
      # cancel always fails, and a dev reset must not cancel a real one either.
      Subscription.where.not(status: %w[canceled incomplete_expired]).update_all(status: "canceled")

      # The last active super admin cannot be deleted, and a reset deletes
      # every user.
      User.where(role: "super_admin").update_all(role: "admin")
    end
end

class DemoFamilyRefreshJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options retry: false

  def perform
    return unless Rails.application.config.app_mode.managed? || Setting.demo_family_refresh_enabled

    with_advisory_lock do
      refresh_demo_family if Rails.application.config.app_mode.managed? || Setting.demo_family_refresh_enabled
    end
  end

  private
    def refresh_demo_family
      period_end = Time.current
      period_start = period_end - 24.hours

      demo_email = Rails.application.config_for(:demo).with_indifferent_access.fetch(:email)
      demo_user = User.find_by(email: demo_email)
      old_family = demo_user&.family

      if Rails.application.config.app_mode.self_hosted?
        # Email alone is not proof that a family is disposable. An administrator
        # must explicitly enroll the family whose data will be replaced.
        configured_id = Setting.demo_family_refresh_family_id.presence
        return Rails.logger.warn("Skipped demo family refresh: no family selected") unless configured_id
        return Rails.logger.warn("Skipped demo family refresh: selected family does not have a demo admin") unless demo_user&.role == "admin" && old_family.id.to_s == configured_id.to_s && !old_family.users.super_admin.exists?

        # The generator transfers this global key to the new demo user. Never
        # take it away from a different family on a self-hosted instance.
        monitoring_key = ApiKey.find_by(display_key: ApiKey::DEMO_MONITORING_KEY)
        return Rails.logger.warn("Skipped demo family refresh: monitoring key belongs to another family") if monitoring_key && monitoring_key.user.family_id != old_family.id
      end

      old_family_session_count = sessions_count_for(old_family, period_start:, period_end:)
      newly_created_families_count = Family.where(created_at: period_start...period_end).count

      ActiveRecord::Base.transaction do
        if old_family
          anonymize_family_emails!(old_family)
        end

        Demo::Generator.new.generate_default_data!(skip_clear: true, email: demo_email)
        if Rails.application.config.app_mode.self_hosted?
          new_family = User.find_by!(email: demo_email).family
          Setting.demo_family_refresh_family_id = new_family.id.to_s
          retire_old_family!(old_family) if old_family
        end
      end

      DestroyJob.perform_later(old_family) if old_family

      notify_super_admins!(
        old_family:,
        old_family_session_count:,
        newly_created_families_count:,
        period_start:,
        period_end:
      )
    end

    # Retiring a demo family must close access before its asynchronous deletion.
    # Deletion can fail on unrelated callbacks, and anonymizing email alone
    # leaves sessions and keys usable. The generator transfers the dedicated
    # monitoring key to the replacement before this runs.
    def retire_old_family!(family)
      family.users.find_each do |user|
        SsoIdentityBlock.block_all!(user.oidc_identities, identity_label: user.email)
        user.sessions.delete_all
        user.api_keys.active.visible.update_all(revoked_at: Time.current)
        Doorkeeper::AccessToken.where(resource_owner_id: user.id, revoked_at: nil).update_all(revoked_at: Time.current)
        Doorkeeper::AccessGrant.where(resource_owner_id: user.id, revoked_at: nil).update_all(revoked_at: Time.current)
        user.update_columns(active: false)
      end

      # The generator's synthetic subscription is not a real Stripe object.
      # Mark it canceled so Family's destroy callback does not try Stripe.
      subscription = family.subscription
      subscription.update!(status: :canceled) if subscription&.stripe_id == "sub_demo_123"
    end

    def sessions_count_for(family, period_start:, period_end:)
      return 0 unless family

      Session
        .joins(:user)
        .where(users: { family_id: family.id })
        .where(created_at: period_start...period_end)
        .distinct
        .count(:id)
    end


    def anonymize_family_emails!(family)
      family.users.find_each do |user|
        user.update_columns(
          email: deleted_email_for(user),
          unconfirmed_email: nil,
          updated_at: Time.current
        )
      end
    end

    def with_advisory_lock
      lock_key = advisory_lock_key
      acquired = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_lock(?)", lock_key ])
      )

      unless acquired
        Rails.logger.warn("Skipped demo family refresh: advisory lock unavailable")
        return
      end

      begin
        yield
      ensure
        ActiveRecord::Base.connection.execute(
          ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_unlock(?)", lock_key ])
        )
      end
    end

    def advisory_lock_key
      Digest::MD5.hexdigest("demo_family_refresh").to_i(16) % (2**62)
    end

    def deleted_email_for(user)
      local_part, domain = user.email.split("@", 2)
      "#{local_part}+deleting-#{user.id}-#{SecureRandom.hex(4)}@#{domain}"
    end

    def notify_super_admins!(old_family:, old_family_session_count:, newly_created_families_count:, period_start:, period_end:)
      User.super_admin.find_each do |super_admin|
        DemoFamilyRefreshMailer.with(
          super_admin:,
          old_family_id: old_family&.id,
          old_family_name: old_family&.name,
          old_family_session_count:,
          newly_created_families_count:,
          period_start:,
          period_end:
        ).completed.deliver_later
      end
    end
end

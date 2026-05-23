class DemoFamilyRefreshJob < ApplicationJob
  queue_as :scheduled

  def perform
    return unless Rails.application.config.app_mode.managed?

    period_end = Time.current
    period_start = period_end - 24.hours

    demo_email = Rails.application.config_for(:demo).with_indifferent_access.fetch(:email)
    demo_user = User.find_by(email: demo_email)
    old_family = demo_user&.family

    old_family_session_count = sessions_count_for(old_family, period_start:, period_end:)
    newly_created_families_count = Family.where(created_at: period_start...period_end).count

    if old_family
      delete_old_family_monitoring_key!(old_family)
      anonymize_family_emails!(old_family)
      DestroyJob.perform_later(old_family)
    end

    Demo::Generator.new.generate_default_data!(skip_clear: true, email: demo_email)

    notify_super_admins!(
      old_family:,
      old_family_session_count:,
      newly_created_families_count:,
      period_start:,
      period_end:
    )
  end

  private

    def sessions_count_for(family, period_start:, period_end:)
      return 0 unless family

      Session
        .joins(:user)
        .where(users: { family_id: family.id })
        .where(created_at: period_start...period_end)
        .distinct
        .count(:id)
    end


    def delete_old_family_monitoring_key!(family)
      ApiKey
        .where(user_id: family.users.select(:id), display_key: ApiKey::DEMO_MONITORING_KEY)
        .delete_all
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

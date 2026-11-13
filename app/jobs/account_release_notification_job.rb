# Daily e-mail release reminders. Without args (cron) it fans
# out one job per family with preview features; with a family id it mails
# every member who chose e-mail a digest of the reminders due for the accounts
# that count in their own finances, using their own lead time.
#
# The feed channel needs no job of its own: GenerateInsightsJob runs
# Insight::Generators::AccountReleaseGenerator.
class AccountReleaseNotificationJob < ApplicationJob
  queue_as :scheduled

  def perform(family_id: nil)
    if family_id.present?
      notify_family(family_id)
    else
      Family.with_preview_features.find_each do |family|
        AccountReleaseNotificationJob.perform_later(family_id: family.id)
      end
    end
  end

  private
    def notify_family(family_id)
      family = Family.find_by(id: family_id)
      return unless family

      today = Account.liquidity_today_for(family)
      family.users.with_preview_features.where(active: true).find_each do |user|
        next unless user.account_release_emails? && user.email.present?

        notify_user(family, user, today)
      rescue => e
        DebugLogEntry.capture(
          category: "account_release",
          level: "error",
          message: "Release reminder e-mail failed: #{e.class}: #{e.message}",
          source: "AccountReleaseNotificationJob",
          family: family,
          metadata: { user_id: user.id }
        )
      end
    end

    def notify_user(family, user, today)
      accounts = Account::ReleaseReminder.candidates(family.accounts.included_in_finances_for(user))
      reminders = Account::ReleaseReminder.for(accounts.to_a, date: today, lead_days: user.account_release_lead_days)
      new_reminders = AccountReleaseNotice.record_for(user: user, reminders: reminders)
      return if new_reminders.empty?

      begin
        AccountAvailabilityMailer.release_digest(user: user, reminders: new_reminders).deliver_now
      rescue
        # Not sent, so not recorded either: tomorrow's run tries again.
        AccountReleaseNotice.forget(user: user, reminders: new_reminders)
        raise
      end
    end
end

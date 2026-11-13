# The e-mail channel for release reminders: one digest per
# person listing every locked account that is released soon, has been
# released, or is about to renew. Its own mailer on purpose, not an insight
# sent by mail; AccountReleaseNotificationJob decides who gets what.
class AccountAvailabilityMailer < ApplicationMailer
  helper AccountReleaseHelper

  def release_digest(user:, reminders:)
    @user = user
    @reminders = reminders
    @accounts_url = accounts_url

    # The person's own language, falling back to the family's: the job runs
    # outside any request.
    I18n.with_locale(user.locale.presence || user.family.locale) do
      mail(
        to: user.email,
        subject: t(".subject", count: reminders.size, product_name: product_name)
      )
    end
  end
end

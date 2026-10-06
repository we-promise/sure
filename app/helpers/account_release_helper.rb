module AccountReleaseHelper
  # One line per release reminder for the e-mail digest: when the money is
  # released, or when a renewing deposit renews.
  def account_release_line(reminder)
    scope = "account_availability_mailer.release_digest.lines"
    date = l(reminder.release_on, format: :long)

    case reminder.kind
    when "upcoming"
      t("#{scope}.upcoming", date: date, count: reminder.days_until)
    when "released"
      t("#{scope}.released", date: date)
    when "renewal"
      "#{t("#{scope}.renewal", date: date)} #{t("#{scope}.cancel_hint")}"
    end
  end
end

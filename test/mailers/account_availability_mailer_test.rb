require "test_helper"

class AccountAvailabilityMailerTest < ActionMailer::TestCase
  setup do
    @user = users(:family_admin)
    @today = Date.new(2026, 10, 5)
  end

  test "release digest lists each reminder" do
    upcoming = reminder(account("Term deposit", available_on: @today + 10), kind: "upcoming")
    renewal = Account::ReleaseReminder.new(
      account: account("Rolling deposit", available_on: @today + 20, auto_renew: true, renewal_term_months: 6),
      kind: "renewal", release_on: @today + 20, date: @today
    )

    mail = AccountAvailabilityMailer.release_digest(user: @user, reminders: [ upcoming, renewal ])

    assert_equal [ @user.email ], mail.to
    assert_equal I18n.t("account_availability_mailer.release_digest.subject", count: 2,
                        product_name: Rails.configuration.x.product_name), mail.subject

    text = mail.text_part.body.decoded
    assert_match "Term deposit", text
    assert_match "Available on #{I18n.l(@today + 10, format: :long)} (in 10 days)", text
    assert_match "cancel before then", text
    assert_match "Renews automatically on #{I18n.l(@today + 20, format: :long)}", text
    assert_match %r{/accounts}, mail.html_part.body.decoded
  end

  test "release digest follows the locale" do
    reminder = reminder(account("Festgeld", available_on: @today), kind: "released")

    @user.update!(locale: "de")

    mail = AccountAvailabilityMailer.release_digest(user: @user, reminders: [ reminder ])

    assert_match "Verfügbar seit", mail.text_part.body.decoded
    assert_equal "1 Freigabe-Hinweis auf #{Rails.configuration.x.product_name}", mail.subject
  end

  private
    def account(name, **attributes)
      @user.family.accounts.create!(name: name, balance: 5000, currency: "USD", owner: @user,
                                    accountable: Depository.new(subtype: "cd"), **attributes)
    end

    def reminder(account, kind:)
      Account::ReleaseReminder.new(account: account, kind: kind, release_on: account.available_on, date: @today)
    end
end

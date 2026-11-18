require "test_helper"

class EmailConfirmationMailerTest < ActionMailer::TestCase
  test "confirmation_email" do
    user = users(:new_email)
    user.unconfirmed_email = "new@example.com"

    mail = EmailConfirmationMailer.with(user: user).confirmation_email
    assert_equal I18n.t("email_confirmation_mailer.confirmation_email.subject", product_name: Rails.configuration.x.product_name), mail.subject
    assert_equal [ user.unconfirmed_email ], mail.to
    assert_equal [ "hello@example.com" ], mail.from
    assert_match "confirm", mail.body.encoded
  end

  test "sends initial verification to the current email" do
    user = users(:family_member)
    user.update!(email_verified_at: nil, unconfirmed_email: nil)

    mail = EmailConfirmationMailer.with(user: user).confirmation_email

    assert_equal I18n.t("email_confirmation_mailer.confirmation_email.verify_subject"), mail.subject
    assert_equal [ user.email ], mail.to
    assert_match "Verify email address", mail.body.encoded
  end
end

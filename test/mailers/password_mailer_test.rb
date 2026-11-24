require "test_helper"

class PasswordMailerTest < ActionMailer::TestCase
  setup { @user = users(:family_admin) }

  test "password_reset links to the web reset form" do
    email = PasswordMailer.with(user: @user).password_reset

    assert_equal [ @user.email ], email.to
    assert_match "/password_reset/edit", email.body.decoded
    assert_no_match "/password_reset/mobile_redirect", email.body.decoded
  end

  test "mobile_password_reset links to the bridge page" do
    email = PasswordMailer.with(user: @user).mobile_password_reset

    assert_equal [ @user.email ], email.to
    assert_match "/password_reset/mobile_redirect", email.body.decoded
    assert_no_match "/password_reset/edit", email.body.decoded
  end

  test "both reset emails render the shared translated template" do
    # The shared copy contains an apostrophe the template HTML-escapes, so
    # compare against the rendered text, not the escaped source.
    shared_copy = I18n.t("password_mailer.password_reset.ignore_if_not_requested")

    web = PasswordMailer.with(user: @user).password_reset
    mobile = PasswordMailer.with(user: @user).mobile_password_reset

    assert_match shared_copy, rendered_text(web)
    assert_match shared_copy, rendered_text(mobile)
  end

  private

    def rendered_text(email)
      Nokogiri::HTML(email.body.decoded).text
    end
end

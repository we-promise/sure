require "test_helper"

class TradeRepublicMailerTest < ActionMailer::TestCase
  test "auto_login_failed tells an admin that a manual login is needed and links to the settings" do
    user = users(:family_admin)

    mail = TradeRepublicMailer.with(user: user).auto_login_failed

    assert_equal [ user.email ], mail.to
    assert_equal I18n.t("trade_republic_mailer.auto_login_failed.subject", product_name: Rails.configuration.x.product_name), mail.subject
    body = mail.body.encoded
    assert_includes body, "http://example.com/settings/providers#trade-republic"
    assert_includes body, I18n.t("trade_republic_mailer.auto_login_failed.manual_login")
  end

  test "auto_login_failed never carries login secrets" do
    item = trade_republic_items(:configured_item)
    item.update!(pin: "987654", pending_login_state: "pending-state-b64")

    mail = TradeRepublicMailer.with(user: users(:family_admin)).auto_login_failed

    assert_not_includes mail.body.encoded, "987654"
    assert_not_includes mail.body.encoded, "pending-state-b64"
  end
end

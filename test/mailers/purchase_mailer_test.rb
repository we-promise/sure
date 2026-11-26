require "test_helper"

class PurchaseMailerTest < ActionMailer::TestCase
  setup do
    @user = users(:family_admin)
    @purchase = purchases(:allegro_matched)
    @purchase.update!(merchant: "Amazon.com", order_number: "112-1234567-1234567", total: BigDecimal("10.00"), currency: "USD")
  end

  test "processed lists the items and the linked transaction" do
    mail = PurchaseMailer.with(purchase: @purchase).processed

    assert_equal [ @user.email ], mail.to
    assert_equal I18n.t("purchase_mailer.processed.subject", merchant: "Amazon.com", total: "$10.00"), mail.subject
    body = mail.text_part.body.decoded
    assert_includes body, "Coffee beans"
    assert_includes body, "Food & Drink"
    assert_includes body, "Starbucks"
  end

  test "an unknown currency is shown as read, not a crash" do
    @purchase.update!(currency: "ZL", total: BigDecimal("12.50"))

    mail = PurchaseMailer.with(purchase: @purchase).processed

    assert_includes mail.subject, "12.5 ZL"
  end

  test "processed says it waits for the payment when nothing is linked" do
    purchase = purchases(:allegro_awaiting)

    body = PurchaseMailer.with(purchase:).processed.text_part.body.decoded

    assert_includes body, I18n.t("purchase_mailer.processed.waiting")
  end

  test "a transaction on an account the owner can no longer see is left out" do
    Account.stubs(:accessible_by).returns(Account.none)

    body = PurchaseMailer.with(purchase: @purchase).matched.text_part.body.decoded

    refute_includes body, "Starbucks"
  end

  test "matched names the transaction" do
    body = PurchaseMailer.with(purchase: @purchase).matched.text_part.body.decoded

    assert_includes body, "Starbucks"
  end

  test "needs_matching says the payment couldn't be picked" do
    purchase = purchases(:allegro_awaiting)

    mail = PurchaseMailer.with(purchase:).needs_matching

    assert_equal [ @user.email ], mail.to
    assert_includes mail.text_part.body.decoded, I18n.t("purchase_mailer.needs_matching.body", total: purchase.amount_text(purchase.total))
  end

  # The purchase pages come with the web UI; until then the emails link nowhere.
  test "no email links to a purchase page" do
    purchase = purchases(:allegro_awaiting)
    purchase.update!(status: :rejected)
    purchase.flag!(:duplicate, purchase_id: @purchase.id)

    %i[processed matched unmatched needs_matching failed].each do |action|
      mail = PurchaseMailer.with(purchase: @purchase).public_send(action)
      [ mail.text_part, mail.html_part ].each { |part| refute_match %r{/purchases}, part.body.decoded, action }
    end
    refute_match %r{/purchases}, PurchaseMailer.with(purchase:).rejected.html_part.body.decoded
  end

  test "rejected gives the model's reason and the email subject" do
    purchase = purchases(:allegro_awaiting)
    purchase.update!(status: :rejected, ai_metadata: { "raw_output" => { "not_order_reason" => "Shipping notification" }, "subject" => "Your package has shipped" })
    purchase.flag!(:not_an_order)

    body = PurchaseMailer.with(purchase:).rejected.text_part.body.decoded

    assert_includes body, "Shipping notification"
    assert_includes body, "Your package has shipped"
  end

  test "rejected as a duplicate says the order is already there" do
    purchase = purchases(:allegro_awaiting)
    purchase.update!(status: :rejected)
    purchase.flag!(:duplicate, purchase_id: @purchase.id)

    body = PurchaseMailer.with(purchase:).rejected.text_part.body.decoded

    assert_includes body, I18n.t("purchase_mailer.rejected.duplicate")
  end

  test "failed never shows the provider's error message" do
    purchase = purchases(:allegro_awaiting)
    purchase.update!(status: :failed, error: "secret upstream detail")

    mail = PurchaseMailer.with(purchase:).failed

    refute_includes mail.text_part.body.decoded, "secret upstream detail"
    refute_includes mail.html_part.body.decoded, "secret upstream detail"
  end

  test "preview_required points at the preferences" do
    mail = PurchaseMailer.with(user: @user).preview_required

    assert_equal [ @user.email ], mail.to
    assert_includes mail.text_part.body.decoded, routes.settings_preferences_url(host: "example.com")
  end

  test "uses the user's locale when set" do
    @user.update!(locale: "pl")

    expected = I18n.with_locale(:pl) do
      I18n.t("purchase_mailer.processed.subject", merchant: "Amazon.com", total: Money.new(BigDecimal("10"), "USD").format)
    end

    I18n.with_locale(:en) do
      assert_equal expected, PurchaseMailer.with(purchase: @purchase).processed.subject
    end
    assert_not_equal "$10.00", expected.split(", ").last
  end

  private
    # Not included: under eager loading its test_* route helpers would run as tests.
    def routes = Rails.application.routes.url_helpers
end

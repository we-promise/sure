require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "#title(page_title)" do
    title("Test Title")
    assert_equal "Test Title", content_for(:title)
  end

  test "#header_title(page_title)" do
    header_title("Test Header Title")
    assert_equal "Test Header Title", content_for(:header_title)
  end

  def setup
    @account1 = Account.new(currency: "USD", balance: 1)
    @account2 = Account.new(currency: "USD", balance: 2)
    @account3 = Account.new(currency: "EUR", balance: -7)
  end

  test "#totals_by_currency(collection: collection, money_method: money_method)" do
    assert_equal "$3.00", totals_by_currency(collection: [ @account1, @account2 ], money_method: :balance_money)
    assert_equal "$3.00 | -€7.00", totals_by_currency(collection: [ @account1, @account2, @account3 ], money_method: :balance_money)
    assert_equal "", totals_by_currency(collection: [], money_method: :balance_money)
    assert_equal "$0.00", totals_by_currency(collection: [ Account.new(currency: "USD", balance: 0) ], money_method: :balance_money)
    assert_equal "-$3.00 | €7.00", totals_by_currency(collection: [ @account1, @account2, @account3 ], money_method: :balance_money, negate: true)
  end

  test "#stripe_one_time_contribution_text(url) renders the contribution link when available" do
    link_text = I18n.t("settings.payments.show.one_time_contribution_link_text")
    payment_text = I18n.t("settings.payments.show.payment_via_stripe")

    expected_html = <<~HTML
      #{payment_text} (
        <a class="font-medium text-primary hover:underline transition" target="_blank" rel="noopener noreferrer" href="https://buy.stripe.com/test_payment_link">#{link_text}</a>
      )
    HTML

    actual_html = stripe_one_time_contribution_text("https://buy.stripe.com/test_payment_link")

    assert_dom_equal expected_html, actual_html
  end

  test "#stripe_one_time_contribution_text(url) renders default stripe payment text when unavailable" do
    assert_equal I18n.t("settings.payments.show.payment_via_stripe"), stripe_one_time_contribution_text(nil)
  end
end

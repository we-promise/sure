require "test_helper"

class AccountsLogoViewTest < ActionView::TestCase
  setup do
    @account = accounts(:depository)
  end

  test "a logo sits over the initials and removes itself when it fails to load" do
    render partial: "accounts/logo", locals: { account: @account, url: "https://example.com/logo.png" }

    assert_select "span.relative" do
      assert_select "div", text: @account.name.first
      assert_select "img[src='https://example.com/logo.png'][onerror=?]", ProviderLogo::REMOVE_ON_ERROR
    end
  end

  test "an account without a logo shows only the initials" do
    render partial: "accounts/logo", locals: { account: @account, url: nil }

    assert_select "img", count: 0
    assert_select "div", text: @account.name.first
  end
end

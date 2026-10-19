require "test_helper"

class AccountsLogoViewTest < ActionView::TestCase
  setup do
    @account = accounts(:depository)
  end

  test "a logo keeps the initials hidden in the page for when the image fails" do
    render partial: "accounts/logo", locals: { account: @account, url: "https://example.com/logo.png" }

    assert_select "[data-controller=image-fallback]" do
      assert_select "img[src='https://example.com/logo.png'][data-image-fallback-target=image]"
      assert_select "[data-image-fallback-target=fallback].hidden", text: @account.name.first
    end
  end

  test "an account without a logo shows only the initials" do
    render partial: "accounts/logo", locals: { account: @account, url: nil }

    assert_select "img", count: 0
    assert_select "[data-controller=image-fallback]", count: 0
    assert_select "div", text: @account.name.first
  end
end

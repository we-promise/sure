require "test_helper"

class AccountExcludeFromReportsCompatibilityViewTest < ActionView::TestCase
  setup do
    Current.session = sessions(:one)
    @account = accounts(:depository)
    original_respond_to = @account.method(:respond_to?)
    @account.define_singleton_method(:respond_to?) do |method_name, include_private = false|
      next false if method_name == :exclude_from_reports?

      original_respond_to.call(method_name, include_private)
    end
    @account.expects(:exclude_from_reports?).never
  end

  teardown do
    Current.reset
  end

  test "account row renders while the exclusion predicate is unavailable" do
    html = render(partial: "accounts/account", locals: { account: @account })

    assert_includes html, @account.name
    assert_not_includes html, toggle_exclude_from_reports_account_path(@account)
  end

  test "account menu renders while the exclusion predicate is unavailable" do
    html = render(partial: "accounts/show/menu", locals: { account: @account })

    assert_includes html, account_sharing_path(@account)
    assert_not_includes html, toggle_exclude_from_reports_account_path(@account)
  end
end

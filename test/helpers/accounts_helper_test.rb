require "test_helper"

class AccountsHelperTest < ActionView::TestCase
  setup do
    @user = users(:family_admin)
    Current.session = @user.sessions.create!
  end

  teardown { Current.session = nil }

  test "sidebar cache key changes with the account order" do
    @user.update!(default_account_order: "name_asc")
    name_key = sidebar_key

    @user.update!(default_account_order: "balance_desc")

    assert_not_equal name_key, sidebar_key
  end

  test "sidebar cache key changes when the manual order changes" do
    @user.update!(default_account_order: "manual")
    before = sidebar_key

    @user.update_manual_account_order("depository", [ accounts(:connected).id, accounts(:depository).id ])

    assert_not_equal before, sidebar_key
  end

  test "sidebar cache key changes the next day" do
    before = sidebar_key

    travel 1.day do
      assert_not_equal before, sidebar_key
    end
  end

  test "sidebar cache key changes when a provider link is removed" do
    link = AccountProvider.create!(account: accounts(:depository), provider: plaid_accounts(:one))
    before = sidebar_key

    link.destroy!

    assert_not_equal before, sidebar_key
  end

  private
    def sidebar_key
      account_sidebar_tabs_cache_key(family: @user.family, active_tab: "all", mobile: false)
    end
end

require "test_helper"

class AccountsHelperTest < ActionView::TestCase
  include AccountsHelper

  setup do
    @user = users(:family_admin)
    Current.session = @user.sessions.create!
  end

  teardown do
    Current.reset
  end

  test "sidebar cache key changes when the default account order changes" do
    @user.update!(default_account_order: "name_asc")
    before = account_sidebar_tabs_cache_key(family: @user.family, active_tab: "all", mobile: false)

    @user.update!(default_account_order: "balance_desc")
    after = account_sidebar_tabs_cache_key(family: @user.family, active_tab: "all", mobile: false)

    assert_not_equal before, after
  end
end

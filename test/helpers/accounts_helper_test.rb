require "test_helper"

class AccountsHelperTest < ActionView::TestCase
  include AccountsHelper

  setup do
    @family = families(:dylan_family)
  end

  test "sidebar cache key changes when a Brandfetch client id is configured" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)
    without_key = account_sidebar_tabs_cache_key(family: @family, active_tab: "all", mobile: false)

    Setting.stubs(:brand_fetch_client_id).returns("test-client-id")
    with_key = account_sidebar_tabs_cache_key(family: @family, active_tab: "all", mobile: false)

    assert_not_equal without_key, with_key
  end
end

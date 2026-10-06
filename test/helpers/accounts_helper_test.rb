require "test_helper"

class AccountsHelperTest < ActionView::TestCase
  include AccountsHelper

  test "sidebar fragment cache key varies with liability balance sign preference" do
    Current.session = sessions(:one)
    family = families(:dylan_family)

    default_key = account_sidebar_tabs_cache_key(family: family, active_tab: "all", mobile: false)
    Current.user.update!(preferences: { "negative_liability_balances" => true })
    opted_in_key = account_sidebar_tabs_cache_key(family: family, active_tab: "all", mobile: false)

    assert_not_equal default_key, opted_in_key
  ensure
    Current.reset
  end
end

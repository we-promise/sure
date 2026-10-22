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

  test "the sidebar is sortable only when grouped by account type first" do
    @user.update!(default_account_order: "manual")
    assert account_sidebar_sortable?

    @user.update!(preferences: @user.preferences.merge(
      "preview_features_enabled" => true,
      "account_grouping" => { "sidebar" => "institution" }
    ))
    assert account_sidebar_sortable?, "each subgroup is reordered within its type"

    @user.update!(preferences: @user.preferences.merge(
      "account_grouping" => {},
      "account_grouping_primary" => { "sidebar" => "custom_group" }
    ))
    assert_not account_sidebar_sortable?, "another first level mixes account types"

    @user.update!(preferences: @user.preferences.merge("account_grouping_primary" => {}))
    assert account_sidebar_sortable?

    @user.update!(default_account_order: "name_asc")
    assert_not account_sidebar_sortable?
  end

  private
    def sidebar_key
      account_sidebar_tabs_cache_key(family: @user.family, active_tab: "all", mobile: false)
    end
end

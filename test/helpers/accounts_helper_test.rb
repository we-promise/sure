require "test_helper"

class AccountsHelperTest < ActionView::TestCase
  setup do
    @user = users(:family_admin)
    Current.session = @user.sessions.create!
  end

  # Pins the version segment literally so bumping it (the only invalidation
  # mechanism now that the sidebar fragment cache skips template digesting)
  # requires a deliberate change here too, rather than silently drifting.
  test "account_sidebar_tabs_cache_key is versioned by account_sidebar_tabs_v2" do
    key = account_sidebar_tabs_cache_key(family: @user.family, active_tab: "overview", mobile: false)

    assert_equal @user.family.build_cache_key("account_sidebar_tabs_v2", invalidate_on_data_updates: true), key.first
  end

  test "account_sidebar_tabs_cache_key changes when family data invalidation key changes" do
    key_before = account_sidebar_tabs_cache_key(family: @user.family, active_tab: "overview", mobile: false)

    @user.family.update!(latest_sync_completed_at: 1.hour.from_now)

    key_after = account_sidebar_tabs_cache_key(family: @user.family, active_tab: "overview", mobile: false)

    assert_not_equal key_before, key_after
  end
end

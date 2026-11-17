require "test_helper"

class AccountsHelperTest < ActionView::TestCase
  include AccountsHelper

  setup do
    @user = users(:family_admin)
    @co_owner = users(:family_member)
    @account = accounts(:depository)
    Current.session = @user.sessions.create!
    @family = @user.family
  end

  teardown { Current.session = nil }

  test "sidebar cache key changes with the Brandfetch client id" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)
    without_key = account_sidebar_tabs_cache_key(family: @family, active_tab: "all", mobile: false)

    Setting.stubs(:brand_fetch_client_id).returns("test-client-id")
    with_key = account_sidebar_tabs_cache_key(family: @family, active_tab: "all", mobile: false)

    assert_not_equal without_key, with_key

    Setting.stubs(:brand_fetch_client_id).returns("other-client-id")
    other_key = account_sidebar_tabs_cache_key(family: @family, active_tab: "all", mobile: false)
    assert_not_equal with_key, other_key

    Setting.stubs(:brand_fetch_logo_size).returns(120)
    assert_not_equal other_key, account_sidebar_tabs_cache_key(family: @family, active_tab: "all", mobile: false)
  end

  test "logo caption names where the shown icon comes from" do
    account = accounts(:depository)
    account.update!(institution_domain: "tbank.ru")
    Setting.stubs(:brand_fetch_client_id).returns(nil)
    assert_equal I18n.t("accounts.logo_caption.none"), account_logo_caption(account)

    Setting.stubs(:brand_fetch_client_id).returns("test-client-id")
    assert_equal I18n.t("accounts.logo_caption.brandfetch"), account_logo_caption(account)

    account.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "tbank.ru.png",
                        metadata: { "logo_source" => "yandex", "logo_auto" => true })
    assert_equal I18n.t("accounts.logo_caption.yandex"), account_logo_caption(account)

    account.update!(logo_selection: "brandfetch")
    assert_equal I18n.t("accounts.logo_caption.brandfetch"), account_logo_caption(account)
  end

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

  test "ownership badge is hidden for a fully owned account" do
    assert_nil ownership_badge_label(@account)
  end

  test "ownership badge shows the owner's percentage" do
    @account.update!(ownership_percentage: 60)

    assert_equal "60%", ownership_badge_label(@account)
  end

  test "ownership badge shows a co-owner's own percentage, not the owner's" do
    @account.update!(ownership_percentage: 60)
    @account.account_shares.find_by!(user: @co_owner).update!(ownership_percentage: 40)
    Current.session = @co_owner.sessions.create!

    assert_equal "40%", ownership_badge_label(@account.reload)
  end

  test "ownership badge keeps meaningful decimals and drops trailing zeros" do
    @account.update!(ownership_percentage: 33.33)

    assert_equal "33.33%", ownership_badge_label(@account)
  end

  test "ownership badge is hidden for a co-owner counting the whole account" do
    @account.update!(ownership_percentage: 60)
    Current.session = @co_owner.sessions.create!

    assert_nil ownership_badge_label(@account.reload)
  end

  private
    def sidebar_key
      account_sidebar_tabs_cache_key(family: @user.family, active_tab: "all", mobile: false)
    end
end

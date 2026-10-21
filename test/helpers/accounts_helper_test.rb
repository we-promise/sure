require "test_helper"

class AccountsHelperTest < ActionView::TestCase
  include AccountsHelper

  setup do
    @family = families(:dylan_family)
  end

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

    account.update!(prefer_brandfetch_logo: true)
    assert_equal I18n.t("accounts.logo_caption.brandfetch"), account_logo_caption(account)
  end
end

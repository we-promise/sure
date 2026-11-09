require "test_helper"

class AccountsHelperTest < ActionView::TestCase
  include AccountsHelper

  setup do
    @user = users(:family_admin)
    Current.session = @user.sessions.create!
    @family = @user.family
  end

  teardown { Current.session = nil }

  test "a sidebar logo's wrapper id stays the same while its stored logo's URL expires and changes" do
    account = accounts(:depository)
    account.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "logo.png", content_type: "image/png")
    ActiveStorage.stubs(:urls_expire_in).returns(7.days)

    first_url, first_id = account.logo_url, sidebar_logo_wrapper_id("asset_depository", account, "#000")
    travel 1.minute do
      assert_not_equal first_url, Account.find(account.id).logo_url, "the stored logo's URL carries its expiry"
      assert_equal first_id, sidebar_logo_wrapper_id("asset_depository", Account.find(account.id), "#000")
    end

    account.logo.attach(io: file_fixture("profile_image.png").open, filename: "other.png", content_type: "image/png")
    assert_not_equal first_id, sidebar_logo_wrapper_id("asset_depository", account.reload, "#000"), "another image is another logo"
  end

  # The wrapper is carried across visits as it is, reconciliation dot included,
  # so a changed status has to replace it.
  test "a sidebar logo's wrapper id changes with its reconciliation status" do
    account = accounts(:depository)
    ids = [ nil, :needs_attention, :matched ].map { |status| sidebar_logo_wrapper_id("asset_depository", account, "#000", status) }

    assert_equal 3, ids.uniq.size
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

  private
    def sidebar_key
      account_sidebar_tabs_cache_key(family: @user.family, active_tab: "all", mobile: false)
    end
end

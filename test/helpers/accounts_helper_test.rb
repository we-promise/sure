require "test_helper"

class AccountsHelperTest < ActionView::TestCase
  include AccountsHelper

  setup do
    @user = users(:family_admin)
    Current.session = @user.sessions.create!
    @family = @user.family
  end

  teardown { Current.session = nil }

  test "a sidebar group lists its accounts one by one when ordered by hand, else its entries" do
    2.times { |index| @family.accounts.create!(name: "Wise #{index}", balance: 10, currency: @family.currency, institution_name: "Wise", accountable: Depository.new) }
    group = @family.balance_sheet.account_groups.find { |account_group| account_group.key == "depository" }

    assert_equal group.accounts, sidebar_group_entries(group, sortable: true)
    assert_includes sidebar_group_entries(group, sortable: false).map(&:class), BalanceSheet::AccountGroup::InstitutionBundle
  end

  test "a sidebar group opens as asked, or for the institution page being viewed" do
    2.times { |index| @family.accounts.create!(name: "Wise #{index}", balance: 10, currency: @family.currency, institution_name: "Wise", accountable: Depository.new) }
    group = @family.balance_sheet.account_groups.find { |account_group| account_group.key == "depository" }
    entries = sidebar_group_entries(group, sortable: false)
    bundle = entries.find { |entry| entry.is_a?(BalanceSheet::AccountGroup::InstitutionBundle) }
    stubs(:page_active?).returns(false)

    assert sidebar_group_open?(group, entries, open: true)
    assert_not sidebar_group_open?(group, entries)

    stubs(:sidebar_active_institution_group_slug).returns(bundle.slug)
    assert sidebar_group_open?(group, entries)
    assert_not sidebar_group_open?(group, entries, open: false)
  end

  test "a sidebar logo's wrapper id stays the same through the day, as its stored logo's URL does" do
    account = accounts(:depository)
    account.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "logo.png", content_type: "image/png")
    ActiveStorage.stubs(:urls_expire_in).returns(7.days)

    first_url = first_id = nil
    travel_to Time.zone.local(2026, 11, 10, 9) do
      first_url, first_id = account.logo_url, sidebar_logo_wrapper_id("asset_depository", account, "#000")

      travel 8.hours
      assert_equal first_url, Account.find(account.id).logo_url
      assert_equal first_id, sidebar_logo_wrapper_id("asset_depository", Account.find(account.id), "#000")
    end

    account.logo.attach(io: file_fixture("profile_image.png").open, filename: "other.png", content_type: "image/png")
    assert_not_equal first_id, sidebar_logo_wrapper_id("asset_depository", account.reload, "#000"), "another image is another logo"
  end

  # A kept logo keeps the URL it was rendered with. One that hasn't loaded yet
  # (in a closed group) must not be kept past that URL's expiry.
  test "a sidebar logo's wrapper id changes from one day to the next where stored logo URLs expire" do
    account = accounts(:depository)
    account.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "logo.png", content_type: "image/png")
    ActiveStorage.stubs(:urls_expire_in).returns(7.days)

    travel_to Time.zone.local(2026, 11, 10, 9) do
      morning = sidebar_logo_wrapper_id("asset_depository", Account.find(account.id), "#000")

      travel 8.hours
      assert_equal morning, sidebar_logo_wrapper_id("asset_depository", Account.find(account.id), "#000")

      travel 1.day
      assert_not_equal morning, sidebar_logo_wrapper_id("asset_depository", Account.find(account.id), "#000")
    end
  end

  # The same image uploaded again is a new blob, and the old one is purged: a
  # kept wrapper would point at the purged blob.
  test "a sidebar logo's wrapper id changes when the same image is uploaded again" do
    account = accounts(:depository)
    account.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "logo.png", content_type: "image/png")
    first_id = sidebar_logo_wrapper_id("asset_depository", account.reload, "#000")

    account.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "logo.png", content_type: "image/png")

    assert_not_equal first_id, sidebar_logo_wrapper_id("asset_depository", account.reload, "#000")
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

  test "sidebar cache key changes when an institution's bundle settings are saved" do
    before = sidebar_key
    settings = @family.institution_groups.create!(key: "chase")
    created = sidebar_key
    assert_not_equal before, created

    travel 1.second do
      settings.update!(currency: "EUR")
    end
    assert_not_equal created, sidebar_key
  end

  private
    def sidebar_key
      account_sidebar_tabs_cache_key(family: @user.family, active_tab: "all", mobile: false)
    end
end

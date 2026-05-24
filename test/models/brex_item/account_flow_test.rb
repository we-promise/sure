# frozen_string_literal: true

require "test_helper"

class BrexItem::AccountFlowTest < ActiveSupport::TestCase
  setup do
    SyncJob.stubs(:perform_later)
    @family = families(:dylan_family)
    @brex_item = brex_items(:one)
  end

  test "requires explicit item when multiple credentialed connections exist" do
    BrexItem.create!(
      family: @family,
      name: "Second Brex",
      token: "second_brex_token",
      base_url: "https://api.brex.com"
    )

    flow = BrexItem::AccountFlow.new(family: @family)

    assert_not flow.selected?
    assert flow.selection_required?
  end

  test "preload payload returns explicit selection error when multiple connections exist" do
    BrexItem.create!(
      family: @family,
      name: "Second Brex",
      token: "second_brex_token",
      base_url: "https://api.brex.com"
    )

    payload = BrexItem::AccountFlow.new(family: @family).preload_payload

    assert_equal false, payload[:success]
    assert_equal "select_connection", payload[:error]
    assert_nil payload[:has_accounts]
  end

  test "preload payload treats cached empty accounts as a cache hit" do
    cache_key = BrexItem::AccountFlow.cache_key(@family, @brex_item)
    Rails.cache.expects(:read).with(cache_key).returns([])
    Rails.cache.expects(:write).never
    @brex_item.expects(:brex_provider).never

    payload = BrexItem::AccountFlow.new(family: @family, brex_item: @brex_item).preload_payload

    assert payload[:success]
    assert_equal false, payload[:has_accounts]
    assert_equal true, payload[:cached]
  end

  test "account cache keys isolate multiple credentialed connections with shared upstream ids" do
    second_item = BrexItem.create!(
      family: @family,
      name: "Second Brex",
      token: "second_brex_token",
      base_url: "https://api.brex.com"
    )
    first_cache_key = BrexItem::AccountFlow.cache_key(@family, @brex_item)
    second_cache_key = BrexItem::AccountFlow.cache_key(@family, second_item)

    refute_equal first_cache_key, second_cache_key

    Rails.cache.expects(:read).with(first_cache_key).never
    Rails.cache.expects(:read).with(second_cache_key).returns(
      [ { id: BrexAccount.card_account_id, name: "Second Brex Card", account_kind: "card" } ]
    )
    Rails.cache.expects(:write).never

    result = BrexItem::AccountFlow.new(family: @family, brex_item: second_item).select_accounts_result(accountable_type: "CreditCard")

    assert result.success?
    assert_equal [ "Second Brex Card" ], result.available_accounts.map { |account| account.with_indifferent_access[:name] }
  end

  test "preload payload reports invalid explicit connection as selection error" do
    payload = BrexItem::AccountFlow.new(
      family: @family,
      brex_item_id: " #{SecureRandom.uuid} "
    ).preload_payload

    assert_equal false, payload[:success]
    assert_equal "select_connection", payload[:error]
    assert_nil payload[:has_accounts]
  end

  test "import accounts reports missing selected item as no api token" do
    flow = BrexItem::AccountFlow.new(family: @family, brex_item_id: SecureRandom.uuid)

    assert_raises BrexItem::AccountFlow::NoApiTokenError do
      flow.import_accounts_from_api_if_needed
    end
  end

  test "link result returns navigation instead of raising expected selection errors" do
    BrexItem.create!(
      family: @family,
      name: "Second Brex",
      token: "second_brex_token",
      base_url: "https://api.brex.com"
    )

    result = BrexItem::AccountFlow.new(family: @family).link_new_accounts_result(
      account_ids: [ "cash_import_1" ],
      accountable_type: "Depository"
    )

    assert_equal :settings_providers, result.target
    assert_equal :alert, result.flash_type
    assert_equal I18n.t("brex_items.link_accounts.select_connection"), result.message
  end

  test "link new accounts rejects unsupported account type before creating accounts" do
    flow = BrexItem::AccountFlow.new(family: @family, brex_item: @brex_item)
    @brex_item.expects(:brex_provider).never

    assert_no_difference [ "Account.count", "BrexAccount.count", "AccountProvider.count" ] do
      result = flow.link_new_accounts_result(
        account_ids: [ "cash_import_1" ],
        accountable_type: "Investment"
      )

      assert_equal :new_account, result.target
      assert_equal :alert, result.flash_type
      assert_equal I18n.t("brex_items.link_accounts.invalid_account_type"), result.message
    end
  end

  test "link new accounts converts unexpected errors into navigation alerts" do
    flow = BrexItem::AccountFlow.new(family: @family, brex_item: @brex_item)
    flow.expects(:link_new_accounts!).raises(StandardError, "link failure")

    result = flow.link_new_accounts_result(
      account_ids: [ "cash_import_1" ],
      accountable_type: "Depository"
    )

    assert_equal :new_account, result.target
    assert_equal :alert, result.flash_type
    assert_equal I18n.t("brex_items.errors.unexpected_error"), result.message
  end

  test "link existing account converts unexpected errors into navigation alerts" do
    account = @family.accounts.create!(
      name: "Manual Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    flow = BrexItem::AccountFlow.new(family: @family, brex_item: @brex_item)
    flow.expects(:link_existing_account!).raises(StandardError, "link existing failure")

    result = flow.link_existing_account_result(account: account, brex_account_id: "cash_import_1")

    assert_equal :accounts, result.target
    assert_equal :alert, result.flash_type
    assert_equal I18n.t("brex_items.errors.unexpected_error"), result.message
  end

  test "imports provider accounts into the selected item" do
    brex_item = BrexItem.create!(
      family: @family,
      name: "Import Brex",
      token: "import_brex_token",
      base_url: "https://api.brex.com"
    )

    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(
      accounts: [
        {
          id: "cash_import_1",
          name: "Imported Cash",
          account_kind: "cash",
          current_balance: { amount: 12_345, currency: "USD" },
          account_number: "account-last4-3456"
        }
      ]
    )
    brex_item.expects(:brex_provider).returns(provider)

    flow = BrexItem::AccountFlow.new(family: @family, brex_item: brex_item)

    assert_difference -> { brex_item.brex_accounts.count }, 1 do
      assert_nil flow.import_accounts_from_api_if_needed
    end

    brex_account = brex_item.brex_accounts.find_by!(account_id: "cash_import_1")
    assert_equal "Imported Cash", brex_account.name
    assert_equal "3456", brex_account.raw_payload["account_number_last4"]
    refute_includes brex_account.raw_payload.to_s, "account-last4-3456"
  end

  test "refreshes existing provider accounts during setup discovery" do
    brex_item = BrexItem.create!(
      family: @family,
      name: "Refresh Brex",
      token: "refresh_brex_token",
      base_url: "https://api.brex.com"
    )
    brex_item.brex_accounts.create!(
      account_id: "cash_import_1",
      name: "Old Cash",
      currency: "USD",
      account_kind: "cash",
      current_balance: 1
    )

    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(
      accounts: [
        {
          id: "cash_import_1",
          name: "Updated Cash",
          account_kind: "cash",
          current_balance: { amount: 12_345, currency: "USD" }
        }
      ]
    )
    brex_item.expects(:brex_provider).returns(provider)

    flow = BrexItem::AccountFlow.new(family: @family, brex_item: brex_item)

    assert_no_difference -> { brex_item.brex_accounts.count } do
      assert_nil flow.import_accounts_from_api_if_needed
    end

    brex_account = brex_item.brex_accounts.find_by!(account_id: "cash_import_1")
    assert_equal "Updated Cash", brex_account.name
    assert_equal BigDecimal("123.45"), brex_account.current_balance
  end

  test "complete setup result is unsuccessful when any account creation fails" do
    first_brex_account = @brex_item.brex_accounts.create!(
      account_id: "setup_result_partial_1",
      account_kind: "cash",
      name: "Setup Result Partial One",
      currency: "USD",
      current_balance: 100
    )
    second_brex_account = @brex_item.brex_accounts.create!(
      account_id: "setup_result_partial_2",
      account_kind: "cash",
      name: "Setup Result Partial Two",
      currency: "USD",
      current_balance: 100
    )
    second_brex_account.update_column(:name, nil)

    result = BrexItem::AccountFlow.new(family: @family, brex_item: @brex_item).complete_setup_result(
      account_types: {
        first_brex_account.id => "Depository",
        second_brex_account.id => "Depository"
      },
      account_subtypes: {}
    )

    refute result.success?
    assert_match(/failed/i, result.message)
    assert first_brex_account.reload.account_provider.present?
    assert_nil second_brex_account.reload.account_provider
  end

  test "complete setup creates account links with default subtype" do
    brex_account = @brex_item.brex_accounts.create!(
      account_id: "setup_cash_1",
      account_kind: "cash",
      name: "Setup Cash",
      currency: "USD",
      current_balance: 100
    )

    flow = BrexItem::AccountFlow.new(family: @family, brex_item: @brex_item)

    assert_difference "AccountProvider.count", 1 do
      result = flow.complete_setup!(
        account_types: { brex_account.id => "Depository" },
        account_subtypes: {}
      )

      assert_equal 1, result.created_count
      assert_equal 0, result.skipped_count
    end

    account = brex_account.reload.account
    assert_equal "Setup Cash", account.name
    assert_equal Depository::DEFAULT_SUBTYPE, account.accountable.subtype
  end

  test "complete setup keeps prior accounts when one account creation fails" do
    first_brex_account = @brex_item.brex_accounts.create!(
      account_id: "setup_partial_1",
      account_kind: "cash",
      name: "Setup Partial One",
      currency: "USD",
      current_balance: 100
    )
    second_brex_account = @brex_item.brex_accounts.create!(
      account_id: "setup_partial_2",
      account_kind: "cash",
      name: "Setup Partial Two",
      currency: "USD",
      current_balance: 100
    )
    second_brex_account.update_column(:name, nil)

    result = BrexItem::AccountFlow.new(family: @family, brex_item: @brex_item).complete_setup!(
      account_types: {
        first_brex_account.id => "Depository",
        second_brex_account.id => "Depository"
      },
      account_subtypes: {}
    )

    assert_equal 1, result.created_count
    assert_equal 1, result.failed_count
    assert first_brex_account.reload.account_provider.present?
    assert_nil second_brex_account.reload.account_provider
  end

  test "link new accounts rolls back account creation when provider link fails" do
    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(
      accounts: [
        {
          id: "rollback_cash_1",
          name: "Rollback Cash",
          account_kind: "cash",
          current_balance: { amount: 12_345, currency: "USD" }
        }
      ]
    )
    @brex_item.expects(:brex_provider).returns(provider)
    AccountProvider.expects(:create!).raises(ActiveRecord::RecordInvalid.new(AccountProvider.new))

    flow = BrexItem::AccountFlow.new(family: @family, brex_item: @brex_item)

    assert_no_difference [ "Account.count", "BrexAccount.count", "AccountProvider.count" ] do
      assert_raises(ActiveRecord::RecordInvalid) do
        flow.link_new_accounts!(account_ids: [ "rollback_cash_1" ], accountable_type: "Depository")
      end
    end
  end

  test "link existing account rolls back provider account when link creation fails" do
    account = @family.accounts.create!(
      name: "Existing Cash",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(
      accounts: [
        {
          id: "rollback_existing_cash_1",
          name: "Rollback Existing Cash",
          account_kind: "cash",
          current_balance: { amount: 12_345, currency: "USD" }
        }
      ]
    )
    @brex_item.expects(:brex_provider).returns(provider)
    AccountProvider.expects(:create!).raises(ActiveRecord::RecordInvalid.new(AccountProvider.new))

    flow = BrexItem::AccountFlow.new(family: @family, brex_item: @brex_item)

    assert_no_difference [ "BrexAccount.count", "AccountProvider.count" ] do
      assert_raises(ActiveRecord::RecordInvalid) do
        flow.link_existing_account!(account: account, brex_account_id: "rollback_existing_cash_1")
      end
    end
  end

  test "complete setup result returns localized notice" do
    brex_account = @brex_item.brex_accounts.create!(
      account_id: "setup_result_cash_1",
      account_kind: "cash",
      name: "Setup Result Cash",
      currency: "USD",
      current_balance: 100
    )

    result = BrexItem::AccountFlow.new(family: @family, brex_item: @brex_item).complete_setup_result(
      account_types: { brex_account.id => "Depository" },
      account_subtypes: {}
    )

    assert result.success?
    assert_equal I18n.t("brex_items.complete_account_setup.success", count: 1), result.message
  end
end

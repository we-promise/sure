require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class Account::LinkableTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
  end

  test "linked? returns true when account has providers" do
    plaid_account = plaid_accounts(:one)
    AccountProvider.create!(account: @account, provider: plaid_account)

    assert @account.linked?
  end

  test "linked? returns false when account has no providers" do
    assert @account.unlinked?
  end

  test "provider preserves legacy fallback without balance policy history" do
    AccountProvider.create!(account: @account, provider: plaid_accounts(:one))

    assert_instance_of Provider::PlaidAdapter, @account.provider
    assert_equal "plaid", @account.provider_name
  end

  test "transaction policy alone does not remove legacy balance fallback" do
    with_provider_encryption do
      external = create_external_account(create_provider_connection)
      link = AccountProvider.create!(account: @account, external_account: external)
      Account::SourcePolicy.select!(account: @account, account_provider: link, resource: "transactions")

      assert_instance_of Provider::ExternalAccountAdapter, @account.provider
      assert_equal external.provider_connection, @account.provider.item
    end
  end

  test "provider follows explicit balance authority rather than the first link" do
    with_provider_encryption do
      first = AccountProvider.create!(account: @account, external_account: create_external_account(create_provider_connection))
      second_external = create_external_account(create_provider_connection(provider_key: "mercury"))
      second = AccountProvider.create!(account: @account, external_account: second_external)
      Account::SourcePolicy.select!(account: @account, account_provider: first, resource: "balances")
      selected = Account::SourcePolicy.select!(account: @account, account_provider: second, resource: "balances")

      assert_equal second_external.provider_connection, @account.provider.item
      assert_equal [ selected.id ], @account.source_policies.active.pluck(:id)
    end
  end

  test "deactivated balance selection does not fall back even while its link remains" do
    with_provider_encryption do
      link = AccountProvider.create!(account: @account, external_account: create_external_account(create_provider_connection))
      selected = Account::SourcePolicy.select!(account: @account, account_provider: link, resource: "balances")
      selected.update!(active: false)

      assert @account.linked?
      assert_nil @account.provider
      assert_nil @account.provider_name
      assert_equal [ link.id ], @account.account_providers.pluck(:id)
    end
  end

  test "detaching selected balances retains history without promoting the remaining source" do
    with_provider_encryption do
      selected_link = AccountProvider.create!(account: @account, external_account: create_external_account(create_provider_connection))
      remaining_external = create_external_account(create_provider_connection(provider_key: "mercury"))
      remaining_link = AccountProvider.create!(account: @account, external_account: remaining_external)
      selected = Account::SourcePolicy.select!(account: @account, account_provider: selected_link, resource: "balances")
      selected.update!(active: false)
      retained = selected.reload.attributes
      selected_link.destroy!

      assert @account.linked?
      refute @account.manual?
      assert_nil @account.provider
      assert_nil @account.provider_name
      assert_equal retained, selected.reload.attributes
      assert_equal [ remaining_link.id ], @account.account_providers.pluck(:id)
      assert_equal [ remaining_external.provider_connection ], @account.providers.map(&:item)

      replacement = Account::SourcePolicy.select!(account: @account, account_provider: remaining_link, resource: "balances")

      assert_equal 2, replacement.revision
      assert_equal remaining_external.provider_connection, @account.provider.item
      assert_equal retained, selected.reload.attributes
    end
  end

  test "providers returns all provider adapters" do
    plaid_account = plaid_accounts(:one)
    AccountProvider.create!(account: @account, provider: plaid_account)

    providers = @account.providers
    assert_equal 1, providers.count
    assert_kind_of Provider::PlaidAdapter, providers.first
  end

  test "provider_for returns specific provider adapter" do
    plaid_account = plaid_accounts(:one)
    AccountProvider.create!(account: @account, provider: plaid_account)

    adapter = @account.provider_for("PlaidAccount")
    assert_kind_of Provider::PlaidAdapter, adapter
  end

  test "linked_to? checks if account is linked to specific provider type" do
    plaid_account = plaid_accounts(:one)
    AccountProvider.create!(account: @account, provider: plaid_account)

    assert @account.linked_to?("PlaidAccount")
    refute @account.linked_to?("SimplefinAccount")
  end

  test "supports_category_matcher? returns true for Plaid-linked accounts" do
    plaid_account = plaid_accounts(:one)
    AccountProvider.create!(account: @account, provider: plaid_account)

    assert @account.supports_category_matcher?
  end

  test "supports_category_matcher? returns true for legacy plaid_account_id links" do
    plaid_account = plaid_accounts(:one)
    @account.update!(plaid_account: plaid_account)

    assert @account.supports_category_matcher?
  end

  test "supports_category_matcher? returns true for Up-linked accounts" do
    up_item = UpItem.create!(family: @family, name: "Test Up", access_token: "up-access-token")
    up_account = UpAccount.create!(up_item: up_item, name: "Up Spending", account_id: "up_acc_1", currency: "AUD")
    AccountProvider.create!(account: @account, provider: up_account)

    assert @account.supports_category_matcher?
  end

  test "supports_category_matcher? returns true for Monobank-linked accounts" do
    AccountProvider.create!(account: @account, provider: monobank_accounts(:black_card))

    assert @account.supports_category_matcher?
  end

  test "supports_category_matcher? returns false for unlinked accounts and providers without a matcher" do
    refute @account.supports_category_matcher?

    simplefin_item = SimplefinItem.create!(
      family: @family,
      name: "Test SimpleFin",
      access_url: "https://example.com/access_token"
    )
    simplefin_account = SimplefinAccount.create!(
      simplefin_item: simplefin_item,
      name: "Test Account",
      account_id: "test-acct",
      currency: "USD",
      account_type: "checking",
      current_balance: 0
    )
    @account.update!(simplefin_account: simplefin_account)

    refute @account.supports_category_matcher?
  end

  test "can_delete_holdings? returns true for unlinked accounts" do
    assert @account.unlinked?
    assert @account.can_delete_holdings?
  end

  test "can_delete_holdings? returns false when any provider disallows deletion" do
    plaid_account = plaid_accounts(:one)
    AccountProvider.create!(account: @account, provider: plaid_account)

    # PlaidAdapter.can_delete_holdings? returns false by default
    refute @account.can_delete_holdings?
  end

  test "can_delete_holdings? returns true only when all providers allow deletion" do
    plaid_account = plaid_accounts(:one)
    AccountProvider.create!(account: @account, provider: plaid_account)

    # Stub all providers to return true
    @account.providers.each do |provider|
      provider.stubs(:can_delete_holdings?).returns(true)
    end

    assert @account.can_delete_holdings?
  end

  # The `linked` scope mirrors `linked?` at the SQL level. These tests pin
  # all three link types so a future schema or `linked?` change breaks the
  # test instead of silently diverging (e.g. wrong sparkline aggregation).
  test "linked scope matches accounts linked via account_providers" do
    plaid_account = plaid_accounts(:one)
    AccountProvider.create!(account: @account, provider: plaid_account)

    assert_includes Account.linked, @account
  end

  test "linked scope matches accounts with legacy plaid_account_id" do
    plaid_account = plaid_accounts(:one)
    @account.update!(plaid_account: plaid_account)

    assert_includes Account.linked, @account
  end

  test "linked scope matches accounts with legacy simplefin_account_id" do
    simplefin_item = SimplefinItem.create!(
      family: @family,
      name: "Test SimpleFin",
      access_url: "https://example.com/access_token"
    )
    simplefin_account = SimplefinAccount.create!(
      simplefin_item: simplefin_item,
      name: "Test Account",
      account_id: "test-acct",
      currency: "USD",
      account_type: "checking",
      current_balance: 0
    )
    @account.update!(simplefin_account: simplefin_account)

    assert_includes Account.linked, @account
  end

  test "linked scope excludes manual accounts" do
    assert @account.unlinked?
    refute_includes Account.linked, @account
  end
end

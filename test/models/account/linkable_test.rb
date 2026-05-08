require "test_helper"

class Account::LinkableTest < ActiveSupport::TestCase
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

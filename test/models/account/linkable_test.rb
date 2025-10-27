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
end

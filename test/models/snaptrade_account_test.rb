require "test_helper"

class SnaptradeAccountTest < ActiveSupport::TestCase
  fixtures :families, :snaptrade_items, :snaptrade_accounts
  setup do
    @family = families(:dylan_family)
    @snaptrade_item = snaptrade_items(:configured_item)
    @snaptrade_account = snaptrade_accounts(:fidelity_401k)
  end

  test "validates presence of name" do
    @snaptrade_account.name = nil
    assert_not @snaptrade_account.valid?
    assert_includes @snaptrade_account.errors[:name], "can't be blank"
  end

  test "validates presence of currency" do
    @snaptrade_account.currency = nil
    assert_not @snaptrade_account.valid?
    assert_includes @snaptrade_account.errors[:currency], "can't be blank"
  end

  test "ensure_account_provider! creates link when account provided" do
    account = @family.accounts.create!(
      name: "Test Investment",
      balance: 10000,
      currency: "USD",
      accountable: Investment.new
    )

    assert_nil @snaptrade_account.account_provider

    @snaptrade_account.ensure_account_provider!(account)
    @snaptrade_account.reload

    assert_not_nil @snaptrade_account.account_provider
    assert_equal account, @snaptrade_account.current_account
  end

  test "ensure_account_provider! updates link when account changes" do
    account1 = @family.accounts.create!(
      name: "First Account",
      balance: 10000,
      currency: "USD",
      accountable: Investment.new
    )
    account2 = @family.accounts.create!(
      name: "Second Account",
      balance: 20000,
      currency: "USD",
      accountable: Investment.new
    )

    @snaptrade_account.ensure_account_provider!(account1)
    assert_equal account1, @snaptrade_account.reload.current_account

    @snaptrade_account.ensure_account_provider!(account2)
    assert_equal account2, @snaptrade_account.reload.current_account
  end

  test "ensure_account_provider! is idempotent" do
    account = @family.accounts.create!(
      name: "Test Investment",
      balance: 10000,
      currency: "USD",
      accountable: Investment.new
    )

    @snaptrade_account.ensure_account_provider!(account)
    provider1 = @snaptrade_account.reload.account_provider

    @snaptrade_account.ensure_account_provider!(account)
    provider2 = @snaptrade_account.reload.account_provider

    assert_equal provider1.id, provider2.id
  end

  test "upsert_holdings_snapshot! stores holdings and updates timestamp" do
    holdings = [
      { "symbol" => { "symbol" => "AAPL" }, "units" => 10 },
      { "symbol" => { "symbol" => "MSFT" }, "units" => 5 }
    ]

    @snaptrade_account.upsert_holdings_snapshot!(holdings)

    assert_equal holdings, @snaptrade_account.raw_holdings_payload
    assert_not_nil @snaptrade_account.last_holdings_sync
  end

  test "upsert_activities_snapshot! stores activities and updates timestamp" do
    activities = [
      { "id" => "act1", "type" => "BUY", "amount" => 1000 },
      { "id" => "act2", "type" => "DIVIDEND", "amount" => 50 }
    ]

    @snaptrade_account.upsert_activities_snapshot!(activities)

    assert_equal activities, @snaptrade_account.raw_activities_payload
    assert_not_nil @snaptrade_account.last_activities_sync
  end

  test "upsert_from_snaptrade! extracts data from API response" do
    # Use a Hash that mimics the SnapTrade SDK response structure
    api_response = {
      "id" => "new_account_id",
      "brokerage_authorization" => "auth_xyz",
      "number" => "9999999",
      "name" => "Schwab Brokerage",
      "status" => "active",
      "balance" => {
        "total" => { "amount" => 125000, "currency" => "USD" }
      },
      "meta" => { "type" => "INDIVIDUAL", "institution_name" => "Charles Schwab" }
    }

    @snaptrade_account.upsert_from_snaptrade!(api_response)

    assert_equal "new_account_id", @snaptrade_account.snaptrade_account_id
    assert_equal "auth_xyz", @snaptrade_account.snaptrade_authorization_id
    assert_equal "9999999", @snaptrade_account.account_number
    assert_equal "Schwab Brokerage", @snaptrade_account.name
    assert_equal "Charles Schwab", @snaptrade_account.brokerage_name
    assert_equal 125000, @snaptrade_account.current_balance.to_i
    assert_equal "INDIVIDUAL", @snaptrade_account.account_type
  end

  test "snaptrade_credentials returns credentials from parent item" do
    credentials = @snaptrade_account.snaptrade_credentials

    assert_equal "user_123", credentials[:user_id]
    assert_equal "secret_abc", credentials[:user_secret]
  end

  test "snaptrade_provider returns provider from parent item" do
    provider = @snaptrade_account.snaptrade_provider

    assert_instance_of Provider::Snaptrade, provider
  end
end

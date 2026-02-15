# frozen_string_literal: true

require "test_helper"

class IndexaCapitalAccountTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = indexa_capital_items(:configured_with_token)
    @account = indexa_capital_accounts(:mutual_fund)
  end

  test "belongs to indexa_capital_item" do
    assert_equal @item, @account.indexa_capital_item
  end

  test "validates presence of name" do
    @account.name = nil
    assert_not @account.valid?
  end

  test "validates presence of currency" do
    @account.currency = nil
    assert_not @account.valid?
  end

  test "upsert_from_indexa_capital! updates from API data" do
    data = {
      account_number: "NEWACCT1",
      name: "New Account",
      type: "mutual",
      status: "active",
      currency: "EUR",
      current_balance: 12345.67
    }

    new_account = @item.indexa_capital_accounts.create!(
      name: "Placeholder", currency: "EUR",
      indexa_capital_account_id: "NEWACCT1"
    )
    new_account.upsert_from_indexa_capital!(data)

    new_account.reload
    assert_equal "NEWACCT1", new_account.indexa_capital_account_id
    assert_equal "New Account", new_account.name
    assert_equal "mutual", new_account.account_type
    assert_equal "active", new_account.account_status
    assert_equal 12345.67, new_account.current_balance.to_f
  end

  test "upsert_from_indexa_capital! without balance does not overwrite existing" do
    assert_equal 38905.2136, @account.current_balance.to_f

    data = {
      account_number: "LPYH3MCQ",
      name: "Updated Name",
      type: "mutual",
      status: "active",
      currency: "EUR"
      # No current_balance
    }
    @account.upsert_from_indexa_capital!(data)
    @account.reload

    assert_equal "Updated Name", @account.name
    assert_equal 38905.2136, @account.current_balance.to_f
  end

  test "upsert_from_indexa_capital! stores zero balance correctly" do
    data = {
      account_number: "LPYH3MCQ",
      name: "Zero Balance Account",
      type: "mutual",
      status: "active",
      currency: "EUR",
      current_balance: 0
    }
    @account.upsert_from_indexa_capital!(data)
    @account.reload

    assert_equal 0, @account.current_balance.to_f
  end

  test "upsert_holdings_snapshot! stores holdings data" do
    holdings = [ { instrument: { identifier: "IE00BFPM9V94" }, titles: 32, price: 506.32, amount: 16333.96 } ]
    @account.upsert_holdings_snapshot!(holdings)

    @account.reload
    assert_equal 1, @account.raw_holdings_payload.size
    assert_not_nil @account.last_holdings_sync
  end

  test "upsert_holdings_snapshot! skips when empty" do
    @account.update!(last_holdings_sync: 1.day.ago)
    original_sync = @account.last_holdings_sync

    @account.upsert_holdings_snapshot!([])
    @account.reload

    assert_equal original_sync, @account.last_holdings_sync
  end

  test "ensure_account_provider! creates link" do
    linked_account = Account.create!(
      family: @family, name: "My Fund", balance: 1000, currency: "EUR",
      accountable: Investment.new
    )

    assert_nil @account.account_provider
    @account.ensure_account_provider!(linked_account)

    assert_not_nil @account.account_provider
    assert_equal linked_account, @account.account
  end

  test "ensure_account_provider! is idempotent" do
    linked_account = Account.create!(
      family: @family, name: "My Fund", balance: 1000, currency: "EUR",
      accountable: Investment.new
    )

    @account.ensure_account_provider!(linked_account)
    assert_no_difference "AccountProvider.count" do
      @account.ensure_account_provider!(linked_account)
    end
  end
end

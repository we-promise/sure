require "test_helper"

class PlaidItem::AccountsSnapshotTest < ActiveSupport::TestCase
  setup do
    @plaid_item = plaid_items(:one)
    @plaid_item.plaid_accounts.destroy_all # Clean slate

    @plaid_provider = mock
    @snapshot = PlaidItem::AccountsSnapshot.new(@plaid_item, plaid_provider: @plaid_provider)
  end

  test "fetches accounts" do
    @plaid_provider.expects(:get_item_accounts).with(@plaid_item.access_token).returns(
      OpenStruct.new(accounts: [])
    )
    @snapshot.accounts
  end

  test "fetches transactions data if item supports transactions and any accounts present" do
    @plaid_item.update!(available_products: [ "transactions" ], billed_products: [])

    @snapshot.expects(:accounts).returns([
      OpenStruct.new(
        account_id: "123",
        type: "depository"
      )
    ]).at_least_once

    @plaid_provider.expects(:get_transactions).with(@plaid_item.access_token, next_cursor: nil).returns(
      OpenStruct.new(
        added: [],
        modified: [],
        removed: [],
        cursor: "test_cursor_1"
      )
    ).once
    @plaid_provider.expects(:get_item_investments).never
    @plaid_provider.expects(:get_item_liabilities).never

    @snapshot.get_account_data("123")
  end

  test "does not fetch transactions if no accounts" do
    @plaid_item.update!(available_products: [ "transactions" ], billed_products: [])

    @snapshot.expects(:accounts).returns([]).at_least_once

    @plaid_provider.expects(:get_transactions).never
    @plaid_provider.expects(:get_item_investments).never
    @plaid_provider.expects(:get_item_liabilities).never

    @snapshot.get_account_data("123")
  end

  test "updates next_cursor when fetching transactions" do
    @plaid_item.update!(available_products: [ "transactions" ], billed_products: [], next_cursor: "test_cursor_1")

    @snapshot.expects(:accounts).returns([
      OpenStruct.new(
        account_id: "123",
        type: "depository"
      )
    ]).at_least_once

    @plaid_provider.expects(:get_transactions).with(@plaid_item.access_token, next_cursor: "test_cursor_1").returns(
      OpenStruct.new(
        added: [],
        modified: [],
        removed: [],
        cursor: "test_cursor_2"
      )
    ).once

    @plaid_provider.expects(:get_item_investments).never
    @plaid_provider.expects(:get_item_liabilities).never

    @snapshot.get_account_data("123")
  end

  test "fetches investments data if item supports investments and investment accounts present" do
    @plaid_item.update!(available_products: [ "investments" ], billed_products: [])

    @snapshot.expects(:accounts).returns([
      OpenStruct.new(
        account_id: "123",
        type: "investment"
      )
    ]).at_least_once

    @plaid_provider.expects(:get_transactions).never
    @plaid_provider.expects(:get_item_investments).with(@plaid_item.access_token).once
    @plaid_provider.expects(:get_item_liabilities).never

    @snapshot.get_account_data("123")
  end

  test "keeps securities for an investment account with holdings but no investment transactions" do
    @plaid_item.update!(available_products: [ "investments" ], billed_products: [])
    @snapshot.stubs(:accounts).returns([ OpenStruct.new(account_id: "123", type: "investment") ])

    security = OpenStruct.new(security_id: "sec_1", ticker_symbol: "VTI")
    @plaid_provider.expects(:get_item_investments).with(@plaid_item.access_token).returns(
      OpenStruct.new(
        holdings: [ OpenStruct.new(account_id: "123", security_id: "sec_1") ],
        transactions: [],
        securities: [ security ]
      )
    )

    investments = @snapshot.get_account_data("123").investments_data

    assert_equal [ "sec_1" ], investments.holdings.map(&:security_id)
    assert_equal [ security ], investments.securities
  end

  test "has no securities for an investment account with neither holdings nor transactions" do
    @plaid_item.update!(available_products: [ "investments" ], billed_products: [])
    @snapshot.stubs(:accounts).returns([ OpenStruct.new(account_id: "123", type: "investment") ])

    @plaid_provider.expects(:get_item_investments).with(@plaid_item.access_token).returns(
      OpenStruct.new(
        holdings: [ OpenStruct.new(account_id: "other", security_id: "sec_1") ],
        transactions: [],
        securities: [ OpenStruct.new(security_id: "sec_1") ]
      )
    )

    assert_empty @snapshot.get_account_data("123").investments_data.securities
  end

  test "does not fetch investments if no investment accounts" do
    @plaid_item.update!(available_products: [ "investments" ], billed_products: [])

    @snapshot.expects(:accounts).returns([]).at_least_once

    @plaid_provider.expects(:get_transactions).never
    @plaid_provider.expects(:get_item_investments).never
    @plaid_provider.expects(:get_item_liabilities).never

    @snapshot.get_account_data("123")
  end

  test "fetches liabilities data if item supports liabilities and liabilities accounts present" do
    @plaid_item.update!(available_products: [], billed_products: [ "liabilities" ])

    @snapshot.expects(:accounts).returns([
      OpenStruct.new(
        account_id: "123",
        type: "loan",
        subtype: "student"
      )
    ]).at_least_once

    @plaid_provider.expects(:get_transactions).never
    @plaid_provider.expects(:get_item_investments).never
    @plaid_provider.expects(:get_item_liabilities).with(@plaid_item.access_token).once

    @snapshot.get_account_data("123")
  end

  test "does not fetch liabilities if no liabilities accounts" do
    @plaid_item.update!(available_products: [], billed_products: [ "liabilities" ])

    @snapshot.expects(:accounts).returns([]).at_least_once

    @plaid_provider.expects(:get_transactions).never
    @plaid_provider.expects(:get_item_investments).never
    @plaid_provider.expects(:get_item_liabilities).never

    @snapshot.get_account_data("123")
  end

  test "fetches liabilities for a credit account when liabilities was an additionally consented product" do
    @plaid_item.update!(
      available_products: [],
      billed_products: [],
      raw_payload: { "consented_products" => [ "liabilities" ] }
    )

    @snapshot.expects(:accounts).returns([
      OpenStruct.new(
        account_id: "123",
        type: "credit",
        subtype: "credit card"
      )
    ]).at_least_once

    @plaid_provider.expects(:get_transactions).never
    @plaid_provider.expects(:get_item_investments).never
    @plaid_provider.expects(:get_item_liabilities).with(@plaid_item.access_token).once

    @snapshot.get_account_data("123")
  end

  test "does not fetch liabilities the institution offers but the user did not consent to" do
    # A Depository link consents to transactions and investments only. Plaid
    # still lists liabilities in available_products when the institution
    # offers it, but /liabilities/get then fails with ADDITIONAL_CONSENT_REQUIRED.
    @plaid_item.update!(
      available_products: [ "liabilities" ],
      billed_products: [ "transactions" ],
      raw_payload: { "consented_products" => [ "transactions", "investments" ] }
    )

    @snapshot.expects(:accounts).returns([
      OpenStruct.new(
        account_id: "123",
        type: "credit",
        subtype: "credit card"
      )
    ]).at_least_once

    @plaid_provider.expects(:get_transactions).with(@plaid_item.access_token, next_cursor: nil).returns(
      OpenStruct.new(
        added: [],
        modified: [],
        removed: [],
        cursor: "test_cursor_1"
      )
    ).once
    @plaid_provider.expects(:get_item_investments).never
    @plaid_provider.expects(:get_item_liabilities).never

    @snapshot.get_account_data("123")
  end
end

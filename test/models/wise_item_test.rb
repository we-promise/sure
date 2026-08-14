require "test_helper"

class WiseItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @wise_item = WiseItem.create!(
      family: @family,
      name: "Test Wise",
      token: "test_token",
      profile_id: "123",
      profile_type: :business
    )

    @standard_account = WiseAccount.create!(
      wise_item: @wise_item,
      balance_id: "10000001",
      name: "Wise EUR",
      currency: "EUR",
      raw_payload: { "type" => "STANDARD", "recipient_id" => 99999001 }
    )
    @standard_sure_account = Account.create!(
      family: @family,
      name: "Wise EUR",
      accountable: Depository.new(subtype: "checking"),
      balance: 0,
      currency: "EUR"
    )
    AccountProvider.create!(account: @standard_sure_account, provider: @standard_account)

    @jar_account = WiseAccount.create!(
      wise_item: @wise_item,
      balance_id: "10000002",
      name: "Jar",
      currency: "EUR",
      raw_payload: { "type" => "SAVINGS", "name" => "Jar" }
    )
    @jar_sure_account = Account.create!(
      family: @family,
      name: "Jar",
      accountable: Depository.new(subtype: "savings"),
      balance: 0,
      currency: "EUR"
    )
    AccountProvider.create!(account: @jar_sure_account, provider: @jar_account)
  end

  # link_jar_transfers!

  test "links matching interbalance inflow and outflow entries as a Transfer" do
    inflow_entry  = create_interbalance_entry(@jar_sure_account, "5001", side: :inflow, amount: -1000.0)
    outflow_entry = create_interbalance_entry(@standard_sure_account, "5001", side: :outflow, amount: 1000.0)

    assert_difference "Transfer.count", 1 do
      @wise_item.link_jar_transfers!
    end

    transfer = Transfer.find_by(inflow_transaction_id: inflow_entry.entryable_id)
    assert_not_nil transfer
    assert_equal outflow_entry.entryable_id, transfer.outflow_transaction_id
    assert_equal "confirmed", transfer.status
  end

  test "does not create duplicate Transfer for already-linked pair" do
    inflow_entry  = create_interbalance_entry(@jar_sure_account, "5002", side: :inflow, amount: -2000.0)
    outflow_entry = create_interbalance_entry(@standard_sure_account, "5002", side: :outflow, amount: 2000.0)

    @wise_item.link_jar_transfers!

    assert_no_difference "Transfer.count" do
      @wise_item.link_jar_transfers!
    end
  end

  test "skips unmatched inflow entries with no corresponding outflow" do
    create_interbalance_entry(@jar_sure_account, "5003", side: :inflow, amount: -500.0)

    assert_no_difference "Transfer.count" do
      @wise_item.link_jar_transfers!
    end
  end

  test "links multiple interbalance pairs in one call" do
    create_interbalance_entry(@jar_sure_account, "6001", side: :inflow, amount: -1000.0)
    create_interbalance_entry(@standard_sure_account, "6001", side: :outflow, amount: 1000.0)
    create_interbalance_entry(@jar_sure_account, "6002", side: :inflow, amount: -3000.0)
    create_interbalance_entry(@standard_sure_account, "6002", side: :outflow, amount: 3000.0)

    assert_difference "Transfer.count", 2 do
      @wise_item.link_jar_transfers!
    end
  end

  test "does nothing when no interbalance entries exist" do
    assert_no_difference "Transfer.count" do
      @wise_item.link_jar_transfers!
    end
  end

  private

    def create_interbalance_entry(account, resource_id, side:, amount:)
      external_id = "wise_interbalance_#{resource_id}_#{side}"
      transaction = Transaction.create!(kind: "funds_movement")
      entry = account.entries.create!(
        external_id: external_id,
        source: "wise",
        amount: amount,
        currency: "EUR",
        date: Date.today,
        name: "Transfer to Jar",
        entryable: transaction
      )
      entry
    end
end

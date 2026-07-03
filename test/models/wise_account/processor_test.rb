# frozen_string_literal: true

require "test_helper"

class WiseAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @wise_item = @family.wise_items.create!(name: "Test", api_token: "dummy-token")
    @wise_account = @wise_item.wise_accounts.create!(
      wise_account_id: "balance-test-001",
      wise_profile_id: "profile-001",
      name: "CAD Balance",
      currency: "CAD",
      current_balance: 1500,
      account_type: "STANDARD"
    )
    @account = @family.accounts.create!(
      name: "CAD Checking",
      balance: 0,
      currency: "CAD",
      accountable: Depository.new
    )
    @wise_account.ensure_account_provider!(@account)
    @wise_account.reload
  end

  # ---- Processor ----------------------------------------------------------

  test "processor anchors the account balance from the wise current_balance" do
    @wise_account.update!(current_balance: 2500)

    WiseAccount::Processor.new(@wise_account).process

    assert_equal 2500, @account.reload.balance.to_d
  end

  test "processor is a no-op when the provider account is not linked" do
    @wise_account.account_provider.destroy
    @wise_account.reload

    assert_nothing_raised { WiseAccount::Processor.new(@wise_account).process }
  end

  # ---- Transaction sign convention ----------------------------------------

  test "processor imports a CREDIT transaction as inflow (negative amount)" do
    @wise_account.update!(raw_transactions_payload: [
      {
        "referenceNumber" => "REF001",
        "type" => "CREDIT",
        "date" => "2026-06-01T00:00:00Z",
        "amount" => { "value" => 500.0, "currency" => "CAD" },
        "details" => { "description" => "Salary" }
      }
    ])

    WiseAccount::Processor.new(@wise_account).process

    entry = @account.reload.entries.find_by(source: "wise")
    assert_not_nil entry
    assert entry.amount.negative?, "CREDIT should produce a negative (inflow) entry amount"
    assert_equal(-500.0, entry.amount.to_f)
  end

  test "processor imports a DEBIT transaction as outflow (positive amount)" do
    @wise_account.update!(raw_transactions_payload: [
      {
        "referenceNumber" => "REF002",
        "type" => "DEBIT",
        "date" => "2026-06-02T00:00:00Z",
        "amount" => { "value" => -100.0, "currency" => "CAD" },
        "details" => { "description" => "Coffee" }
      }
    ])

    WiseAccount::Processor.new(@wise_account).process

    entry = @account.reload.entries.find_by(source: "wise")
    assert_not_nil entry
    assert entry.amount.positive?, "DEBIT should produce a positive (outflow) entry amount"
    assert_equal(100.0, entry.amount.to_f)
  end

  test "processor deduplicates transactions by referenceNumber on re-sync" do
    txn = {
      "referenceNumber" => "REF003",
      "type" => "CREDIT",
      "date" => "2026-06-01T00:00:00Z",
      "amount" => { "value" => 200.0, "currency" => "CAD" },
      "details" => { "description" => "Transfer in" }
    }
    @wise_account.update!(raw_transactions_payload: [ txn ])

    WiseAccount::Processor.new(@wise_account).process
    WiseAccount::Processor.new(@wise_account).process

    assert_equal 1, @account.reload.entries.where(source: "wise").count
  end

  test "processor skips transactions with nil amount" do
    @wise_account.update!(raw_transactions_payload: [
      {
        "referenceNumber" => "REF004",
        "type" => "CREDIT",
        "date" => "2026-06-01T00:00:00Z",
        "amount" => { "value" => nil, "currency" => "CAD" }
      }
    ])

    assert_nothing_raised { WiseAccount::Processor.new(@wise_account).process }
    assert_equal 0, @account.reload.entries.where(source: "wise").count
  end
end

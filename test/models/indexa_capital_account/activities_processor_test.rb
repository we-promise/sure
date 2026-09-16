# frozen_string_literal: true

require "test_helper"

class IndexaCapitalAccount::ActivitiesProcessorTest < ActiveSupport::TestCase
  include SecuritiesTestHelper

  setup do
    @family = families(:dylan_family)
    @item = indexa_capital_items(:configured_with_token)
    @indexa_capital_account = indexa_capital_accounts(:mutual_fund)

    @account = @family.accounts.create!(
      name: "Test Investment",
      balance: 10000,
      currency: "EUR",
      accountable: Investment.new
    )

    @indexa_capital_account.ensure_account_provider!(@account)
    @indexa_capital_account.reload
  end

  test "processes contribution cash activity with negative inflow amount" do
    @indexa_capital_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "contrib_001",
        type: "CONTRIBUTION",
        amount: 500.00,
        date: Date.current.to_s
      )
    ])

    processor = IndexaCapitalAccount::ActivitiesProcessor.new(@indexa_capital_account)
    processor.process

    entry = @account.entries.find_by(external_id: "contrib_001", source: "indexa_capital")
    assert_not_nil entry
    assert_equal(-500.00, entry.amount.to_f)
    assert_equal "Contribution", entry.entryable.investment_activity_label
  end

  test "processes dividend cash activity as negative inflow" do
    @indexa_capital_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "div_001",
        type: "DIVIDEND",
        amount: 25.50,
        date: Date.current.to_s,
        symbol: "IE00BFPM9V94"
      )
    ])

    processor = IndexaCapitalAccount::ActivitiesProcessor.new(@indexa_capital_account)
    processor.process

    entry = @account.entries.find_by(external_id: "div_001", source: "indexa_capital")
    assert_not_nil entry
    assert_equal(-25.50, entry.amount.to_f)
    assert_equal "Dividend", entry.entryable.investment_activity_label
  end

  test "processes withdrawal with positive outflow amount" do
    @indexa_capital_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "withdraw_001",
        type: "WITHDRAWAL",
        amount: 200.00,
        date: Date.current.to_s
      )
    ])

    processor = IndexaCapitalAccount::ActivitiesProcessor.new(@indexa_capital_account)
    processor.process

    entry = @account.entries.find_by(external_id: "withdraw_001", source: "indexa_capital")
    assert_not_nil entry
    assert_equal 200.00, entry.amount.to_f
    assert_equal "Withdrawal", entry.entryable.investment_activity_label
  end

  test "processes transfers with Sure sign convention" do
    @indexa_capital_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "transfer_in_001",
        type: "TRANSFER_IN",
        amount: 300.00,
        date: Date.current.to_s
      ),
      build_cash_activity(
        id: "transfer_out_001",
        type: "TRANSFER_OUT",
        amount: 125.00,
        date: Date.current.to_s
      )
    ])

    processor = IndexaCapitalAccount::ActivitiesProcessor.new(@indexa_capital_account)
    processor.process

    transfer_in = @account.entries.find_by(external_id: "transfer_in_001", source: "indexa_capital")
    transfer_out = @account.entries.find_by(external_id: "transfer_out_001", source: "indexa_capital")

    assert_not_nil transfer_in
    assert_not_nil transfer_out
    assert_equal(-300.00, transfer_in.amount.to_f)
    assert_equal 125.00, transfer_out.amount.to_f
    assert_equal "Transfer", transfer_in.entryable.investment_activity_label
    assert_equal "Transfer", transfer_out.entryable.investment_activity_label
  end

  test "processes fee with positive outflow amount" do
    @indexa_capital_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "fee_001",
        type: "FEE",
        amount: 15.00,
        date: Date.current.to_s
      )
    ])

    processor = IndexaCapitalAccount::ActivitiesProcessor.new(@indexa_capital_account)
    processor.process

    entry = @account.entries.find_by(external_id: "fee_001", source: "indexa_capital")
    assert_not_nil entry
    assert_equal 15.00, entry.amount.to_f
    assert_equal "Fee", entry.entryable.investment_activity_label
  end

  test "maps all known activity types correctly" do
    type_mappings = {
      "BUY" => "Buy",
      "SELL" => "Sell",
      "DIVIDEND" => "Dividend",
      "DIV" => "Dividend",
      "CONTRIBUTION" => "Contribution",
      "WITHDRAWAL" => "Withdrawal",
      "TRANSFER_IN" => "Transfer",
      "TRANSFER_OUT" => "Transfer",
      "TRANSFER" => "Transfer",
      "INTEREST" => "Interest",
      "FEE" => "Fee",
      "TAX" => "Fee",
      "REINVEST" => "Reinvestment",
      "SPLIT" => "Other",
      "MERGER" => "Other",
      "OTHER" => "Other"
    }

    type_mappings.each do |indexa_type, expected_label|
      actual = IndexaCapitalAccount::ActivitiesProcessor::ACTIVITY_TYPE_TO_LABEL[indexa_type]
      assert_equal expected_label, actual, "Type #{indexa_type} should map to #{expected_label}"
    end
  end

  test "handles empty payload gracefully" do
    @indexa_capital_account.update!(raw_activities_payload: nil)

    processor = IndexaCapitalAccount::ActivitiesProcessor.new(@indexa_capital_account)
    result = processor.process

    assert_equal({ trades: 0, transactions: 0 }, result)
  end

  private

    def build_cash_activity(id:, type:, amount:, date:, symbol: nil)
      activity = {
        "id" => id,
        "type" => type,
        "amount" => amount,
        "date" => date
      }
      activity["symbol"] = symbol if symbol
      activity
    end
end

require "test_helper"

class SimplefinEntry::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @simplefin_item = SimplefinItem.create!(
      family: @family,
      name: "Test SimpleFin Bank",
      access_url: "https://example.com/access_token"
    )
    @simplefin_account = SimplefinAccount.create!(
      simplefin_item: @simplefin_item,
      name: "SF Checking",
      account_id: "sf_acc_1",
      account_type: "checking",
      currency: "USD",
      current_balance: 1000,
      available_balance: 1000,
      account: @account
    )
  end

  test "persists extra metadata (raw payee/memo/description and provider extra)" do
    tx = {
      id: "tx_1",
      amount: "-12.34",
      currency: "USD",
      payee: "Pizza Hut",
      description: "Order #1234",
      memo: "Carryout",
      posted: Date.today.to_s,
      transacted_at: (Date.today - 1).to_s,
      extra: { category: "restaurants", check_number: nil }
    }

    assert_difference "@account.entries.count", 1 do
      SimplefinEntry::Processor.new(tx, simplefin_account: @simplefin_account).process
    end

    entry = @account.entries.find_by!(external_id: "simplefin_tx_1", source: "simplefin")
    extra = entry.transaction.extra

    assert_equal "Pizza Hut - Order #1234", entry.name
    assert_equal "USD", entry.currency

    # Check extra payload structure
    assert extra.is_a?(Hash), "extra should be a Hash"
    assert extra["simplefin"].is_a?(Hash), "extra.simplefin should be a Hash"
    sf = extra["simplefin"]
    assert_equal "Pizza Hut", sf["payee"]
    assert_equal "Carryout", sf["memo"]
    assert_equal "Order #1234", sf["description"]
    assert_equal({ "category" => "restaurants", "check_number" => nil }, sf["extra"])
  end
end

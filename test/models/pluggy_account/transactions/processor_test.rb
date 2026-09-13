require "test_helper"

class PluggyAccount::Transactions::ProcessorTest < ActiveSupport::TestCase
  test "parse_transaction_amount negates Pluggy amount" do
    p = PluggyAccount::Transactions::Processor.new(pluggy_accounts(:one))
    assert_equal(-100, p.send(:parse_transaction_amount, { "amount" => 100 }))
    assert_equal(50, p.send(:parse_transaction_amount, { "amount" => -50 }))
  end

  test "build_extra_metadata flags pending from status" do
    p = PluggyAccount::Transactions::Processor.new(pluggy_accounts(:one))
    pending = p.send(:build_extra_metadata, { "id" => "t1", "status" => "PENDING", "merchant" => "M", "category" => "C" })
    assert pending["pluggy"]["pending"]
    posted = p.send(:build_extra_metadata, { "id" => "t2", "status" => "POSTED" })
    refute posted["pluggy"]["pending"]
  end

  test "process imports each transaction with negated amount" do
    recorded = []
    fake_adapter = Object.new
    fake_adapter.define_singleton_method(:import_transaction) { |**opts| recorded << opts; true }
    fake_account = OpenStruct.new(currency: "BRL", id: 1)

    acct = pluggy_accounts(:one)
    acct.stubs(:current_account).returns(fake_account)
    acct.stubs(:raw_transactions_payload).returns([
      { "id" => "t1", "amount" => 100, "status" => "POSTED", "date" => "2026-01-01", "currencyCode" => "BRL", "description" => "Coffee" }
    ])
    PluggyAccount::Transactions::Processor.any_instance.stubs(:import_adapter).returns(fake_adapter)

    result = PluggyAccount::Transactions::Processor.new(acct).process
    assert_equal 1, recorded.size
    assert_equal(-100, recorded.first[:amount])
    assert_equal "pluggy", recorded.first[:source]
    assert_equal "t1", recorded.first[:external_id]
  end
end

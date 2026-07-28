# frozen_string_literal: true

require "test_helper"

# Tests PluggyAccount::Processor#process — the per-account dispatcher invoked by
# PluggyItem#process_accounts. Banking accounts delegate to the transactions
# processor; investment accounts delegate to the holdings processor. Balance is
# upserted in both branches. Mirrors the AkahuAccount::ProcessorTest pattern of
# stubbing current_account + child processors rather than wiring a full sync.
class PluggyAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @pluggy_account = pluggy_accounts(:one)

    # Stub the linked Sure account so balance upsert + broadcast stay isolated.
    @account = stub("Account",
                    id: 1,
                    accountable_type: "Depository",
                    currency: "USD",
                    assign_attributes: true,
                    save!: true,
                    set_current_balance: true,
                    broadcast_sync_complete: true)
    @pluggy_account.stubs(:current_account).returns(@account)
    @pluggy_account.stubs(:currency).returns("BRL")
  end

  test "process dispatches banking transactions processor for a banking account" do
    @pluggy_account.stubs(:account_type).returns("checking")
    @pluggy_account.stubs(:raw_payload).returns("type" => "checking")
    @pluggy_account.stubs(:raw_transactions_payload).returns([ { "id" => "tx-1" } ])
    @pluggy_account.stubs(:current_balance).returns(100.0)

    PluggyAccount::Transactions::Processor.any_instance.expects(:process).once

    result = PluggyAccount::Processor.new(@pluggy_account).process
    assert result[:transactions]
  end

  test "process dispatches holdings processor for an investment account" do
    @pluggy_account.stubs(:account_type).returns("investment")
    @pluggy_account.stubs(:raw_payload).returns("type" => "investment")
    @pluggy_account.stubs(:raw_holdings_payload).returns([ { "code" => "PETR4" } ])
    @pluggy_account.stubs(:raw_activities_payload).returns([])
    @pluggy_account.stubs(:current_balance).returns(5000.0)

    PluggyAccount::Investments::HoldingsProcessor.any_instance.expects(:process).once

    result = PluggyAccount::Processor.new(@pluggy_account).process
    assert result[:holdings]
  end

  test "process returns nil when no linked account" do
    @pluggy_account.stubs(:current_account).returns(nil)

    assert_nil PluggyAccount::Processor.new(@pluggy_account).process
  end

  test "process re-raises Pluggy authentication errors" do
    @pluggy_account.stubs(:account_type).returns("checking")
    @pluggy_account.stubs(:raw_payload).returns("type" => "checking")
    @pluggy_account.stubs(:raw_transactions_payload).returns([ { "id" => "tx-1" } ])
    @pluggy_account.stubs(:current_balance).returns(100.0)

    PluggyAccount::Transactions::Processor.any_instance.stubs(:process).raises(
      Provider::Pluggy::AuthenticationError.new("Invalid credentials", :unauthorized)
    )

    assert_raises(Provider::Pluggy::AuthenticationError) do
      PluggyAccount::Processor.new(@pluggy_account).process
    end
  end
end

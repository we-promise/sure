# frozen_string_literal: true

require "test_helper"

class IndexaCapitalAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    # TODO: Create or reference your indexa_capital_item fixture
    # @indexa_capital_item = indexa_capital_items(:configured_item)
    # @indexa_capital_account = indexa_capital_accounts(:test_account)

    # Create a linked Sure account for the provider account
    @account = @family.accounts.create!(
      name: "Test Account",
      balance: 10000,
      currency: "USD",
      accountable: Investment.new
    )

    # TODO: Link the provider account to the Sure account
    # @indexa_capital_account.ensure_account_provider!(@account)
    # @indexa_capital_account.reload
  end

  # ==========================================================================
  # Processor tests
  # ==========================================================================

  test "processor initializes with indexa_capital_account" do
    skip "TODO: Set up indexa_capital_account fixture"

    # processor = IndexaCapitalAccount::Processor.new(@indexa_capital_account)
    # assert_not_nil processor
  end

  test "processor skips processing when no linked account" do
    skip "TODO: Set up indexa_capital_account fixture"

    # Remove the account provider link
    # @indexa_capital_account.account_provider&.destroy
    # @indexa_capital_account.reload

    # processor = IndexaCapitalAccount::Processor.new(@indexa_capital_account)
    # assert_nothing_raised { processor.process }
  end

  test "processor updates account balance" do
    skip "TODO: Set up indexa_capital_account fixture"

    # @indexa_capital_account.update!(current_balance: 15000)
    #
    # processor = IndexaCapitalAccount::Processor.new(@indexa_capital_account)
    # processor.process
    #
    # @account.reload
    # assert_equal 15000, @account.balance.to_f
  end

  # ==========================================================================
  # HoldingsProcessor tests
  # ==========================================================================

  test "holdings processor creates holdings from raw payload" do
    skip "TODO: Set up indexa_capital_account fixture and holdings payload"

    # @indexa_capital_account.update!(raw_holdings_payload: [
    #   {
    #     "symbol" => { "symbol" => "AAPL", "name" => "Apple Inc" },
    #     "units" => 10,
    #     "price" => 150.00,
    #     "currency" => { "code" => "USD" }
    #   }
    # ])
    #
    # processor = IndexaCapitalAccount::HoldingsProcessor.new(@indexa_capital_account)
    # processor.process
    #
    # holding = @account.holdings.find_by(security: Security.find_by(ticker: "AAPL"))
    # assert_not_nil holding
    # assert_equal 10, holding.qty.to_f
  end

  test "holdings processor skips blank symbols" do
    skip "TODO: Set up indexa_capital_account fixture"

    # @indexa_capital_account.update!(raw_holdings_payload: [
    #   { "symbol" => nil, "units" => 10, "price" => 100.00 }
    # ])
    #
    # processor = IndexaCapitalAccount::HoldingsProcessor.new(@indexa_capital_account)
    # assert_nothing_raised { processor.process }
  end

  # ==========================================================================
  # ActivitiesProcessor tests
  # ==========================================================================

  test "activities processor creates trades from raw payload" do
    skip "TODO: Set up indexa_capital_account fixture and activities payload"

    # @indexa_capital_account.update!(raw_activities_payload: [
    #   {
    #     "id" => "trade_001",
    #     "type" => "BUY",
    #     "symbol" => { "symbol" => "AAPL", "name" => "Apple Inc" },
    #     "units" => 10,
    #     "price" => 150.00,
    #     "settlement_date" => Date.current.to_s,
    #     "currency" => { "code" => "USD" }
    #   }
    # ])
    #
    # processor = IndexaCapitalAccount::ActivitiesProcessor.new(@indexa_capital_account)
    # processor.process
    #
    # entry = @account.entries.find_by(external_id: "trade_001", source: "indexa_capital")
    # assert_not_nil entry
    # assert entry.entryable.is_a?(Trade)
  end

  test "activities processor skips activities without external_id" do
    skip "TODO: Set up indexa_capital_account fixture"

    # @indexa_capital_account.update!(raw_activities_payload: [
    #   { "id" => nil, "type" => "BUY", "units" => 10, "price" => 100.00 }
    # ])
    #
    # processor = IndexaCapitalAccount::ActivitiesProcessor.new(@indexa_capital_account)
    # processor.process
    #
    # assert_equal 0, @account.entries.where(source: "indexa_capital").count
  end
end

require "test_helper"

class LunchflowAccount::Investments::HoldingsProcessorTest < ActiveSupport::TestCase
  setup do
    @lunchflow_account = lunchflow_accounts(:investment_account)
    @account = accounts(:investment)

    # Create account_provider to link lunchflow_account to account
    @account_provider = AccountProvider.create!(
      account: @account,
      provider: @lunchflow_account
    )

    # Reload to ensure associations are loaded
    @lunchflow_account.reload
  end

  test "creates holding records from Lunchflow holdings snapshot" do
    # Verify setup is correct
    assert_not_nil @lunchflow_account.current_account, "Account should be linked"
    assert_equal "Investment", @lunchflow_account.current_account.accountable_type

    # Use unique dates to avoid conflicts with existing fixture holdings
    test_holdings_payload = [
      {
        "security" => {
          "name" => "iShares Inc MSCI Brazil",
          "currency" => "USD",
          "tickerSymbol" => "NEWTEST1",
          "figi" => nil,
          "cusp" => nil,
          "isin" => nil
        },
        "quantity" => 5,
        "price" => 42.15,
        "value" => 210.75,
        "costBasis" => 100.0,
        "currency" => "USD",
        "raw" => {
          "quiltt" => {
            "id" => "hld_test_123"
          }
        }
      },
      {
        "security" => {
          "name" => "Test Security",
          "currency" => "USD",
          "tickerSymbol" => "NEWTEST2",
          "figi" => nil,
          "cusp" => nil,
          "isin" => nil
        },
        "quantity" => 10,
        "price" => 150.0,
        "value" => 1500.0,
        "costBasis" => 1200.0,
        "currency" => "USD",
        "raw" => {
          "quiltt" => {
            "id" => "hld_test_456"
          }
        }
      }
    ]

    @lunchflow_account.update!(raw_holdings_payload: test_holdings_payload)

    processor = LunchflowAccount::Investments::HoldingsProcessor.new(@lunchflow_account)

    assert_difference "Holding.count", 2 do
      processor.process
    end

    holdings = Holding.where(account: @account).where.not(external_id: nil).order(:created_at)

    assert_equal 2, holdings.count
    assert_equal "USD", holdings.first.currency
    assert_equal "lunchflow_hld_test_123", holdings.first.external_id
  end

  test "skips processing for non-investment accounts" do
    # Create a depository account
    depository_account = accounts(:depository)
    depository_lunchflow_account = LunchflowAccount.create!(
      lunchflow_item: lunchflow_items(:one),
      account_id: "lf_depository",
      name: "Depository",
      currency: "USD"
    )

    AccountProvider.create!(
      account: depository_account,
      provider: depository_lunchflow_account
    )
    depository_lunchflow_account.reload

    test_holdings_payload = [
      {
        "security" => { "name" => "Test", "tickerSymbol" => "TEST", "currency" => "USD" },
        "quantity" => 10,
        "price" => 100.0,
        "value" => 1000.0,
        "costBasis" => nil,
        "currency" => "USD",
        "raw" => { "quiltt" => { "id" => "hld_skip" } }
      }
    ]

    depository_lunchflow_account.update!(raw_holdings_payload: test_holdings_payload)

    processor = LunchflowAccount::Investments::HoldingsProcessor.new(depository_lunchflow_account)

    assert_no_difference "Holding.count" do
      processor.process
    end
  end

  test "creates synthetic ticker when tickerSymbol is missing" do
    test_holdings_payload = [
      {
        "security" => {
          "name" => "Custom 401k Fund",
          "currency" => "USD",
          "tickerSymbol" => nil,
          "figi" => nil,
          "cusp" => nil,
          "isin" => nil
        },
        "quantity" => 100,
        "price" => 50.0,
        "value" => 5000.0,
        "costBasis" => 4500.0,
        "currency" => "USD",
        "raw" => {
          "quiltt" => {
            "id" => "hld_custom_123"
          }
        }
      }
    ]

    @lunchflow_account.update!(raw_holdings_payload: test_holdings_payload)

    processor = LunchflowAccount::Investments::HoldingsProcessor.new(@lunchflow_account)

    assert_difference "Holding.count", 1 do
      processor.process
    end

    holding = Holding.where(account: @account).where.not(external_id: nil).last
    assert_equal "lunchflow_hld_custom_123", holding.external_id
    assert_equal 100, holding.qty
    assert_equal 5000.0, holding.amount
  end

  test "skips zero value holdings" do
    test_holdings_payload = [
      {
        "security" => {
          "name" => "Zero Position",
          "currency" => "USD",
          "tickerSymbol" => "ZERO",
          "figi" => nil,
          "cusp" => nil,
          "isin" => nil
        },
        "quantity" => 0,
        "price" => 0,
        "value" => 0,
        "costBasis" => nil,
        "currency" => "USD",
        "raw" => {
          "quiltt" => {
            "id" => "hld_zero"
          }
        }
      }
    ]

    @lunchflow_account.update!(raw_holdings_payload: test_holdings_payload)

    Security::Resolver.any_instance.stubs(:resolve).returns(securities(:aapl))

    processor = LunchflowAccount::Investments::HoldingsProcessor.new(@lunchflow_account)

    assert_no_difference "Holding.count" do
      processor.process
    end
  end

  test "handles empty holdings payload gracefully" do
    @lunchflow_account.update!(raw_holdings_payload: [])

    processor = LunchflowAccount::Investments::HoldingsProcessor.new(@lunchflow_account)

    assert_no_difference "Holding.count" do
      processor.process
    end
  end

  test "handles nil holdings payload gracefully" do
    @lunchflow_account.update!(raw_holdings_payload: nil)

    processor = LunchflowAccount::Investments::HoldingsProcessor.new(@lunchflow_account)

    assert_no_difference "Holding.count" do
      processor.process
    end
  end

  test "continues processing other holdings when one fails" do
    test_holdings_payload = [
      {
        "security" => {
          "name" => "Good Holding",
          "currency" => "USD",
          "tickerSymbol" => "GOODTEST",
          "figi" => nil,
          "cusp" => nil,
          "isin" => nil
        },
        "quantity" => 10,
        "price" => 100.0,
        "value" => 1000.0,
        "costBasis" => nil,
        "currency" => "USD",
        "raw" => {
          "quiltt" => {
            "id" => "hld_good"
          }
        }
      },
      {
        "security" => {
          "name" => nil,  # This will cause it to skip (no name, no symbol)
          "currency" => "USD",
          "tickerSymbol" => nil,
          "figi" => nil,
          "cusp" => nil,
          "isin" => nil
        },
        "quantity" => 5,
        "price" => 50.0,
        "value" => 250.0,
        "costBasis" => nil,
        "currency" => "USD",
        "raw" => {
          "quiltt" => {
            "id" => "hld_bad"
          }
        }
      }
    ]

    @lunchflow_account.update!(raw_holdings_payload: test_holdings_payload)

    processor = LunchflowAccount::Investments::HoldingsProcessor.new(@lunchflow_account)

    # Should create 1 holding (the good one)
    assert_difference "Holding.count", 1 do
      processor.process
    end
  end
end

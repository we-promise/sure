require "test_helper"

class Trading212HoldingsProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @trading212_item = trading212_items(:configured_item)
    @trading212_account = trading212_accounts(:main_account)

    # Link to an investment account
    @account = @family.accounts.create!(
      name: "Test T212 Investment",
      balance: 0,
      cash_balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    @trading212_account.ensure_account_provider!(@account)
    @trading212_account.reload
  end

  # === process ===

  test "processor creates holdings from raw positions payload" do
    @trading212_account.update!(
      raw_positions_payload: [
        {
          "instrument" => {
            "ticker" => "AAPL_US_EQ",
            "isin" => "US0378331005",
            "name" => "Apple Inc.",
            "currency" => "USD"
          },
          "quantity" => "50",
          "currentPrice" => "175.00",
          "averagePricePaid" => "150.00"
        }
      ]
    )

    processor = Trading212Account::HoldingsProcessor.new(@trading212_account)
    processor.process

    security = Security.find_by(ticker: "AAPL")
    assert_not_nil security

    holding = @account.holdings.find_by(security: security)
    assert_not_nil holding
    assert_equal BigDecimal("50"), holding.qty
    assert_equal BigDecimal("175.00"), holding.price
  end

  test "processor stores cost basis when available" do
    @trading212_account.update!(
      raw_positions_payload: [
        {
          "instrument" => {
            "ticker" => "TSLA_US_EQ",
            "name" => "Tesla Inc."
          },
          "quantity" => "25",
          "currentPrice" => "250.00",
          "averagePricePaid" => "200.00"
        }
      ]
    )

    processor = Trading212Account::HoldingsProcessor.new(@trading212_account)
    processor.process

    security = Security.find_by(ticker: "TSLA")
    holding = @account.holdings.find_by(security: security)
    assert_not_nil holding
    assert_equal BigDecimal("200.00"), holding.cost_basis
    assert_equal "provider", holding.cost_basis_source
  end

  test "processor skips position with blank ticker" do
    @trading212_account.update!(
      raw_positions_payload: [
        {
          "instrument" => {
            "ticker" => "",
            "name" => "No Ticker"
          },
          "quantity" => "100",
          "currentPrice" => "50.00"
        }
      ]
    )

    processor = Trading212Account::HoldingsProcessor.new(@trading212_account)

    assert_nothing_raised do
      processor.process
    end

    assert_equal 0, @account.holdings.count
  end

  test "processor skips position with zero quantity" do
    @trading212_account.update!(
      raw_positions_payload: [
        {
          "instrument" => {
            "ticker" => "MSFT_US_EQ",
            "name" => "Microsoft"
          },
          "quantity" => "0",
          "currentPrice" => "400.00"
        }
      ]
    )

    processor = Trading212Account::HoldingsProcessor.new(@trading212_account)
    processor.process

    assert_equal 0, @account.holdings.count
  end

  test "processor skips position with nil price" do
    @trading212_account.update!(
      raw_positions_payload: [
        {
          "instrument" => {
            "ticker" => "GOOGL_US_EQ",
            "name" => "Alphabet"
          },
          "quantity" => "10",
          "currentPrice" => nil
        }
      ]
    )

    processor = Trading212Account::HoldingsProcessor.new(@trading212_account)
    processor.process

    assert_equal 0, @account.holdings.count
  end

  test "processor is idempotent - does not duplicate holdings" do
    @trading212_account.update!(
      raw_positions_payload: [
        {
          "instrument" => {
            "ticker" => "NVDA_US_EQ",
            "name" => "Nvidia"
          },
          "quantity" => "30",
          "currentPrice" => "800.00",
          "averagePricePaid" => "600.00"
        }
      ]
    )

    processor = Trading212Account::HoldingsProcessor.new(@trading212_account)
    2.times { processor.process }

    security = Security.find_by(ticker: "NVDA")
    assert_equal 1, @account.holdings.where(security: security).count
  end

  test "processor handles empty positions payload" do
    @trading212_account.update!(raw_positions_payload: [])

    processor = Trading212Account::HoldingsProcessor.new(@trading212_account)
    processor.process

    assert_equal 0, @account.holdings.count
  end

  test "processor returns early when no account linked" do
    @trading212_account.account_provider.destroy!

    @trading212_account.update!(
      raw_positions_payload: [
        {
          "instrument" => { "ticker" => "AAPL_US_EQ", "name" => "Apple" },
          "quantity" => "10",
          "currentPrice" => "150.00"
        }
      ]
    )

    processor = Trading212Account::HoldingsProcessor.new(@trading212_account)
    processor.process

    assert_equal 0, @account.holdings.count
  end

  test "processor gracefully handles individual position errors" do
    # Position without instrument at all
    @trading212_account.update!(
      raw_positions_payload: [
        {
          # Missing instrument key entirely
          "quantity" => "10",
          "currentPrice" => "150.00"
        }
      ]
    )

    processor = Trading212Account::HoldingsProcessor.new(@trading212_account)

    assert_nothing_raised do
      processor.process
    end
  end
end

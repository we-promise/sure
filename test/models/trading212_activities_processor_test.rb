require "test_helper"

class Trading212ActivitiesProcessorTest < ActiveSupport::TestCase
  fixtures :families, :trading212_items, :trading212_accounts, :accounts, :securities
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

  # === process orders (BUY) ===

  test "processes a filled buy order as a Buy trade" do
    @trading212_account.update!(
      raw_orders_payload: [
        {
          "order" => {
            "id" => "order_001",
            "status" => "FILLED",
            "side" => "BUY",
            "instrument" => {
              "ticker" => "AAPL_US_EQ",
              "isin" => "US0378331005",
              "name" => "Apple Inc."
            },
            "filledValue" => "1750.00",
            "createdAt" => "2024-06-15T10:30:00Z"
          },
          "fill" => {
            "id" => "fill_001",
            "quantity" => "10",
            "price" => "175.00",
            "filledAt" => "2024-06-15T10:30:00Z"
          }
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 1, result[:trades]
    entry = @account.entries.find_by(external_id: "trading212_order_fill_001")
    assert_not_nil entry
    assert_equal "Trade", entry.entryable_type
    assert_equal "Buy", entry.entryable.investment_activity_label
    assert entry.entryable.qty.positive?
  end

  test "processes a filled sell order as a Sell trade" do
    @trading212_account.update!(
      raw_orders_payload: [
        {
          "order" => {
            "id" => "order_002",
            "status" => "FILLED",
            "side" => "SELL",
            "instrument" => {
              "ticker" => "TSLA_US_EQ",
              "name" => "Tesla Inc."
            },
            "filledValue" => "2500.00",
            "createdAt" => "2024-06-15T10:30:00Z"
          },
          "fill" => {
            "id" => "fill_002",
            "quantity" => "10",
            "price" => "250.00",
            "filledAt" => "2024-06-15T10:30:00Z"
          }
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 1, result[:trades]
    entry = @account.entries.find_by(external_id: "trading212_order_fill_002")
    assert_equal "Sell", entry.entryable.investment_activity_label
    assert entry.entryable.qty.negative?
  end

  test "stores a foreign-currency fill in the instrument currency with the wallet rate" do
    @account.update!(currency: "CZK")
    @trading212_account.update!(
      currency: "CZK",
      raw_orders_payload: [
        {
          "order" => {
            "id" => 58204391732,
            "status" => "FILLED",
            "side" => "BUY",
            "currency" => "CZK",
            "filledValue" => 3000.0,
            "instrument" => { "ticker" => "NET_US_EQ", "name" => "Cloudflare", "currency" => "USD" }
          },
          "fill" => {
            "id" => 58209573886,
            "quantity" => 0.4,
            "price" => 350.0,
            "filledAt" => "2026-10-01T13:30:03.000Z",
            "walletImpact" => { "currency" => "CZK", "netValue" => 3000.0, "fxRate" => 0.04612801 }
          }
        }
      ]
    )

    Trading212Account::ActivitiesProcessor.new(@trading212_account).process

    entry = @account.entries.find_by(external_id: "trading212_order_58209573886")
    assert_equal "USD", entry.currency
    assert_equal BigDecimal("140"), entry.amount
    assert_equal "USD", entry.entryable.currency
    assert_equal BigDecimal("350"), entry.entryable.price
    # 140 USD at the stored rate is the 3000 CZK the wallet was charged
    assert_in_delta 3000, entry.amount * entry.entryable.exchange_rate, 0.001
  end

  test "treats a negative fill quantity on a sell order as a sale" do
    @account.update!(currency: "CZK")
    @trading212_account.update!(
      currency: "CZK",
      raw_orders_payload: [
        {
          "order" => {
            "id" => 49502407922,
            "status" => "FILLED",
            "side" => "SELL",
            "currency" => "CZK",
            "quantity" => -2.0,
            "instrument" => { "ticker" => "IGLDd_EQ", "name" => "iShares Physical Gold", "currency" => "EUR" }
          },
          "fill" => {
            "id" => 49504676344,
            "quantity" => -2.0,
            "price" => 80.0,
            "filledAt" => "2026-04-13T10:17:54.000Z",
            "walletImpact" => { "currency" => "CZK", "netValue" => 3900.0, "fxRate" => 0.041 }
          }
        }
      ]
    )

    Trading212Account::ActivitiesProcessor.new(@trading212_account).process

    entry = @account.entries.find_by(external_id: "trading212_order_49504676344")
    assert_equal "Sell", entry.entryable.investment_activity_label
    assert_equal BigDecimal("-2"), entry.entryable.qty
    assert_equal BigDecimal("-160"), entry.amount
    assert_equal "Sell 2.0 shares of IGLDD", entry.name
    assert_in_delta(-3900, entry.amount * entry.entryable.exchange_rate, 0.001)
  end

  test "stores a pence-quoted fill in pounds" do
    @account.update!(currency: "CZK")
    @trading212_account.update!(
      currency: "CZK",
      raw_orders_payload: [
        {
          "order" => {
            "id" => "order_gbx",
            "status" => "FILLED",
            "side" => "BUY",
            "currency" => "CZK",
            "instrument" => { "ticker" => "SGLNl_EQ", "name" => "iShares Physical Gold", "currency" => "GBX" }
          },
          "fill" => {
            "id" => "fill_gbx",
            "quantity" => 0.5,
            "price" => 5000.0,
            "filledAt" => "2026-03-10T15:05:50.000Z",
            "walletImpact" => { "currency" => "CZK", "netValue" => 750.0, "fxRate" => 3.5469545 }
          }
        }
      ]
    )

    Trading212Account::ActivitiesProcessor.new(@trading212_account).process

    entry = @account.entries.find_by(external_id: "trading212_order_fill_gbx")
    assert_equal "GBP", entry.currency
    assert_equal BigDecimal("25"), entry.amount
    assert_equal BigDecimal("50"), entry.entryable.price
    assert_in_delta 750, entry.amount * entry.entryable.exchange_rate, 0.001
  end

  test "books the wallet amount without a rate when the instrument is in the account currency" do
    @trading212_account.update!(
      raw_orders_payload: [
        {
          "order" => {
            "id" => "order_same_ccy",
            "status" => "FILLED",
            "side" => "BUY",
            "currency" => "USD",
            "instrument" => { "ticker" => "AAPL_US_EQ", "name" => "Apple", "currency" => "USD" }
          },
          "fill" => {
            "id" => "fill_same_ccy",
            "quantity" => 10,
            "price" => 175.0,
            "filledAt" => "2024-06-15T10:30:00Z",
            "walletImpact" => { "currency" => "USD", "netValue" => 1751.5 }
          }
        }
      ]
    )

    Trading212Account::ActivitiesProcessor.new(@trading212_account).process

    entry = @account.entries.find_by(external_id: "trading212_order_fill_same_ccy")
    assert_equal BigDecimal("1751.5"), entry.amount
    assert_nil entry.entryable.exchange_rate
  end

  test "skips non-filled orders" do
    @trading212_account.update!(
      raw_orders_payload: [
        {
          "order" => {
            "id" => "order_003",
            "status" => "PENDING",
            "side" => "BUY",
            "instrument" => { "ticker" => "MSFT_US_EQ", "name" => "Microsoft" },
            "filledValue" => "400.00",
            "createdAt" => "2024-06-15T10:30:00Z"
          },
          "fill" => {
            "id" => "fill_003",
            "quantity" => "1",
            "price" => "400.00"
          }
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 0, result[:trades]
  end

  test "uses order id as external_id when fill id is absent" do
    @trading212_account.update!(
      raw_orders_payload: [
        {
          "order" => {
            "id" => "order_005",
            "status" => "FILLED",
            "side" => "BUY",
            "instrument" => { "ticker" => "MSFT_US_EQ", "name" => "Microsoft" },
            "filledValue" => "400.00",
            "createdAt" => "2024-06-15T10:30:00Z"
          },
          "fill" => {
            "quantity" => "1",
            "price" => "400.00",
            "filledAt" => "2024-06-15T10:30:00Z"
          }
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 1, result[:trades]
    entry = @account.entries.find_by(external_id: "trading212_order_order_005")
    assert_not_nil entry
  end

  # === process dividends ===

  test "processes dividend as a cash transaction" do
    @trading212_account.update!(
      raw_dividends_payload: [
        {
          "reference" => "div_001",
          "ticker" => "AAPL_US_EQ",
          "amount" => "25.00",
          "paidOn" => "2024-06-15",
          "quantity" => "50",
          "grossAmountPerShare" => "0.50",
          "type" => "ORDINARY"
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 1, result[:dividends]
    entry = @account.entries.find_by(external_id: "trading212_dividend_div_001")
    assert_not_nil entry
    assert_equal "Transaction", entry.entryable_type
    assert_equal "Dividend", entry.entryable.investment_activity_label
    # Dividends are negative in Sure (inflow)
    assert entry.amount.negative?
  end

  test "skips dividend with blank reference" do
    @trading212_account.update!(
      raw_dividends_payload: [
        {
          "ticker" => "AAPL_US_EQ",
          "amount" => "25.00",
          "paidOn" => "2024-06-15"
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 0, result[:dividends]
  end

  test "skips dividend with zero or nil amount" do
    @trading212_account.update!(
      raw_dividends_payload: [
        { "reference" => "div_zero", "amount" => "0", "paidOn" => "2024-06-15" },
        { "reference" => "div_nil", "amount" => nil, "paidOn" => "2024-06-15" }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 0, result[:dividends]
  end

  # === process cash transactions ===

  test "processes DEPOSIT as Contribution" do
    @trading212_account.update!(
      raw_transactions_payload: [
        {
          "reference" => "txn_001",
          "type" => "DEPOSIT",
          "amount" => "1000.00",
          "dateTime" => "2024-06-15T10:00:00Z"
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 1, result[:transactions]
    entry = @account.entries.find_by(external_id: "trading212_transaction_txn_001")
    assert_not_nil entry
    assert_equal "Contribution", entry.entryable.investment_activity_label
    # Deposits are negative in Sure (inflow)
    assert entry.amount.negative?
  end

  test "processes WITHDRAW as Withdrawal" do
    @trading212_account.update!(
      raw_transactions_payload: [
        {
          "reference" => "txn_002",
          "type" => "WITHDRAW",
          "amount" => "500.00",
          "dateTime" => "2024-06-15T10:00:00Z"
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 1, result[:transactions]
    entry = @account.entries.find_by(external_id: "trading212_transaction_txn_002")
    assert_equal "Withdrawal", entry.entryable.investment_activity_label
    assert entry.amount.positive?
  end

  test "processes INTEREST as Interest" do
    @trading212_account.update!(
      raw_transactions_payload: [
        {
          "reference" => "txn_003",
          "type" => "INTEREST",
          "amount" => "5.00",
          "dateTime" => "2024-06-15T10:00:00Z"
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 1, result[:transactions]
    entry = @account.entries.find_by(external_id: "trading212_transaction_txn_003")
    assert_equal "Interest", entry.entryable.investment_activity_label
  end

  test "processes INTEREST_ON_FREE_CASH as Interest" do
    @trading212_account.update!(
      raw_transactions_payload: [
        {
          "reference" => "txn_003_free_cash",
          "type" => "INTEREST_ON_FREE_CASH",
          "amount" => "0.03",
          "currency" => "EUR",
          "dateTime" => "2026-09-09T01:13:26.766Z"
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 1, result[:transactions]
    entry = @account.entries.find_by(external_id: "trading212_transaction_txn_003_free_cash")
    assert_not_nil entry
    assert_equal "Interest", entry.entryable.investment_activity_label
    assert entry.amount.negative?
  end

  test "processes LENDING_INTEREST as Interest" do
    @trading212_account.update!(
      raw_transactions_payload: [
        {
          "reference" => "txn_lending",
          "type" => "LENDING_INTEREST",
          "amount" => "0.04",
          "dateTime" => "2026-10-06T03:58:08.084Z"
        }
      ]
    )

    result = Trading212Account::ActivitiesProcessor.new(@trading212_account).process

    assert_equal 1, result[:transactions]
    entry = @account.entries.find_by(external_id: "trading212_transaction_txn_lending")
    assert_equal "Interest", entry.entryable.investment_activity_label
    assert entry.amount.negative?
  end

  test "processes FEE as Fee" do
    @trading212_account.update!(
      raw_transactions_payload: [
        {
          "reference" => "txn_004",
          "type" => "FEE",
          "amount" => "2.50",
          "dateTime" => "2024-06-15T10:00:00Z"
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 1, result[:transactions]
    entry = @account.entries.find_by(external_id: "trading212_transaction_txn_004")
    assert_equal "Fee", entry.entryable.investment_activity_label
  end

  test "skips transaction with blank reference" do
    @trading212_account.update!(
      raw_transactions_payload: [
        {
          "type" => "DEPOSIT",
          "amount" => "100.00",
          "dateTime" => "2024-06-15T10:00:00Z"
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 0, result[:transactions]
  end

  test "skips transaction with zero amount" do
    @trading212_account.update!(
      raw_transactions_payload: [
        { "reference" => "txn_zero", "type" => "DEPOSIT", "amount" => "0", "dateTime" => "2024-06-15T10:00:00Z" }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 0, result[:transactions]
  end

  # === idempotency ===

  test "processor is idempotent - does not duplicate entries" do
    @trading212_account.update!(
      raw_orders_payload: [
        {
          "order" => {
            "id" => "order_idempotent",
            "status" => "FILLED",
            "side" => "BUY",
            "instrument" => { "ticker" => "AAPL_US_EQ", "name" => "Apple" },
            "filledValue" => "1750.00",
            "createdAt" => "2024-06-15T10:30:00Z"
          },
          "fill" => {
            "id" => "fill_idempotent",
            "quantity" => "10",
            "price" => "175.00"
          }
        }
      ],
      raw_dividends_payload: [
        { "reference" => "div_idempotent", "amount" => "10.00", "paidOn" => "2024-06-15" }
      ],
      raw_transactions_payload: [
        { "reference" => "txn_idempotent", "type" => "DEPOSIT", "amount" => "100.00", "dateTime" => "2024-06-15T10:00:00Z" }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    first_result = processor.process
    second_result = processor.process

    assert_equal first_result, second_result
    assert_equal 1, @account.entries.where(external_id: "trading212_order_fill_idempotent").count
    assert_equal 1, @account.entries.where(external_id: "trading212_dividend_div_idempotent").count
    assert_equal 1, @account.entries.where(external_id: "trading212_transaction_txn_idempotent").count
  end

  # === process returns early without account ===

  test "returns zero counts when no account linked" do
    @trading212_account.account_provider.destroy!

    @trading212_account.update!(
      raw_orders_payload: [
        {
          "order" => { "id" => "o1", "status" => "FILLED", "side" => "BUY",
                       "instrument" => { "ticker" => "AAPL_US_EQ", "name" => "Apple" } },
          "fill" => { "quantity" => "10", "price" => "175.00" }
        }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal({ trades: 0, dividends: 0, transactions: 0 }, result)
  end

  # === combined results ===

  test "returns combined stats for all activity types" do
    @trading212_account.update!(
      raw_orders_payload: [
        {
          "order" => { "id" => "o1", "status" => "FILLED", "side" => "BUY",
                       "instrument" => { "ticker" => "AAPL_US_EQ", "name" => "Apple" } },
          "fill" => { "id" => "f1", "quantity" => "10", "price" => "175.00", "filledAt" => "2024-06-15T10:30:00Z" }
        },
        {
          "order" => { "id" => "o2", "status" => "FILLED", "side" => "SELL",
                       "instrument" => { "ticker" => "TSLA_US_EQ", "name" => "Tesla" } },
          "fill" => { "id" => "f2", "quantity" => "5", "price" => "250.00", "filledAt" => "2024-06-15T11:00:00Z" }
        }
      ],
      raw_dividends_payload: [
        { "reference" => "d1", "amount" => "10.00", "paidOn" => "2024-06-15" }
      ],
      raw_transactions_payload: [
        { "reference" => "t1", "type" => "DEPOSIT", "amount" => "1000.00", "dateTime" => "2024-06-15T10:00:00Z" },
        { "reference" => "t2", "type" => "FEE", "amount" => "2.00", "dateTime" => "2024-06-15T10:00:00Z" }
      ]
    )

    processor = Trading212Account::ActivitiesProcessor.new(@trading212_account)
    result = processor.process

    assert_equal 2, result[:trades]
    assert_equal 1, result[:dividends]
    assert_equal 2, result[:transactions]
  end
end

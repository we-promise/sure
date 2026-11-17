require "test_helper"

class PlaidAccount::Investments::TransactionsProcessorTest < ActiveSupport::TestCase
  setup do
    @plaid_account = plaid_accounts(:one)
    @security_resolver = PlaidAccount::Investments::SecurityResolver.new(@plaid_account)
  end

  test "creates regular trade entries" do
    test_investments_payload = {
      transactions: [
        {
          "investment_transaction_id" => "123",
          "security_id" => "123",
          "type" => "buy",
          "quantity" => 1, # Positive, so "buy 1 share"
          "price" => 100,
          "amount" => 100,
          "iso_currency_code" => "USD",
          "date" => Date.current,
          "name" => "Buy 1 share of AAPL"
        }
      ]
    }

    @plaid_account.update!(raw_holdings_payload: test_investments_payload)

    @security_resolver.stubs(:resolve).returns(OpenStruct.new(
      security: securities(:aapl)
    ))

    processor = PlaidAccount::Investments::TransactionsProcessor.new(@plaid_account, security_resolver: @security_resolver)

    assert_difference [ "Entry.count", "Trade.count" ], 1 do
      processor.process
    end

    entry = Entry.order(created_at: :desc).first

    assert_equal 100, entry.amount
    assert_equal "USD", entry.currency
    assert_equal Date.current, entry.date
    assert_equal "Buy 1 share of AAPL", entry.name
  end

  test "creates cash transactions" do
    test_investments_payload = {
      transactions: [
        {
          "investment_transaction_id" => "cash_123",
          "type" => "cash",
          "subtype" => "withdrawal",
          "amount" => 100, # Positive, so moving money OUT of the account
          "iso_currency_code" => "USD",
          "date" => Date.current,
          "name" => "Withdrawal"
        }
      ]
    }

    @plaid_account.update!(raw_holdings_payload: test_investments_payload)

    @security_resolver.expects(:resolve).never # Cash transactions don't have a security

    processor = PlaidAccount::Investments::TransactionsProcessor.new(@plaid_account, security_resolver: @security_resolver)

    assert_difference [ "Entry.count", "Transaction.count" ], 1 do
      processor.process
    end

    entry = Entry.order(created_at: :desc).first

    assert_equal 100, entry.amount
    assert_equal "USD", entry.currency
    assert_equal Date.current, entry.date
    assert_equal "Withdrawal", entry.name
  end

  test "creates fee transactions" do
    test_investments_payload = {
      transactions: [
        {
          "investment_transaction_id" => "fee_123",
          "type" => "fee",
          "subtype" => "miscellaneous fee",
          "amount" => 10.25,
          "iso_currency_code" => "USD",
          "date" => Date.current,
          "name" => "Miscellaneous fee"
        }
      ]
    }

    @plaid_account.update!(raw_holdings_payload: test_investments_payload)

    @security_resolver.expects(:resolve).never # Cash transactions don't have a security

    processor = PlaidAccount::Investments::TransactionsProcessor.new(@plaid_account, security_resolver: @security_resolver)

    assert_difference [ "Entry.count", "Transaction.count" ], 1 do
      processor.process
    end

    entry = Entry.order(created_at: :desc).first

    assert_equal 10.25, entry.amount
    assert_equal "USD", entry.currency
    assert_equal Date.current, entry.date
    assert_equal "Miscellaneous fee", entry.name
  end

  test "handles bad plaid quantity signage data" do
    test_investments_payload = {
      transactions: [
        {
          "investment_transaction_id" => "123",
          "security_id" => "123",
          "type" => "sell", # Correct type
          "subtype" => "sell", # Correct subtype
          "quantity" => 1, # ***Incorrect signage***, this should be negative
          "price" => 100, # Correct price
          "amount" => -100, # Correct amount
          "iso_currency_code" => "USD",
          "date" => Date.current,
          "name" => "Sell 1 share of AAPL"
        }
      ]
    }

    @plaid_account.update!(raw_holdings_payload: test_investments_payload)

    @security_resolver.expects(:resolve).returns(OpenStruct.new(
      security: securities(:aapl)
    ))

    processor = PlaidAccount::Investments::TransactionsProcessor.new(@plaid_account, security_resolver: @security_resolver)

    assert_difference [ "Entry.count", "Trade.count" ], 1 do
      processor.process
    end

    entry = Entry.order(created_at: :desc).first

    assert_equal -100, entry.amount
    assert_equal "USD", entry.currency
    assert_equal Date.current, entry.date
    assert_equal "Sell 1 share of AAPL", entry.name

    assert_equal -1, entry.trade.qty
  end

  test "creates contribution transactions as cash transactions" do
    test_investments_payload = {
      transactions: [
        {
          "investment_transaction_id" => "contrib_123",
          "type" => "contribution",
          "amount" => -500.0,
          "iso_currency_code" => "USD",
          "date" => Date.current,
          "name" => "401k Contribution"
        }
      ]
    }

    @plaid_account.update!(raw_holdings_payload: test_investments_payload)

    @security_resolver.expects(:resolve).never

    processor = PlaidAccount::Investments::TransactionsProcessor.new(@plaid_account, security_resolver: @security_resolver)

    assert_difference [ "Entry.count", "Transaction.count" ], 1 do
      processor.process
    end

    entry = Entry.order(created_at: :desc).first

    assert_equal(-500.0, entry.amount)
    assert_equal "USD", entry.currency
    assert_equal "401k Contribution", entry.name
    assert_instance_of Transaction, entry.entryable
  end

  test "creates withdrawal transactions as cash transactions" do
    test_investments_payload = {
      transactions: [
        {
          "investment_transaction_id" => "withdraw_123",
          "type" => "withdrawal",
          "amount" => 1000.0,
          "iso_currency_code" => "USD",
          "date" => Date.current,
          "name" => "IRA Withdrawal"
        }
      ]
    }

    @plaid_account.update!(raw_holdings_payload: test_investments_payload)

    @security_resolver.expects(:resolve).never

    processor = PlaidAccount::Investments::TransactionsProcessor.new(@plaid_account, security_resolver: @security_resolver)

    assert_difference [ "Entry.count", "Transaction.count" ], 1 do
      processor.process
    end

    entry = Entry.order(created_at: :desc).first

    assert_equal 1000.0, entry.amount
    assert_equal "USD", entry.currency
    assert_equal "IRA Withdrawal", entry.name
    assert_instance_of Transaction, entry.entryable
  end

  test "creates transfer transactions as cash transactions" do
    test_investments_payload = {
      transactions: [
        {
          "investment_transaction_id" => "123",
          "type" => "transfer",
          "amount" => -100.0,
          "iso_currency_code" => "USD",
          "date" => Date.current,
          "name" => "Bank Transfer"
        }
      ]
    }

    @plaid_account.update!(raw_holdings_payload: test_investments_payload)

    @security_resolver.expects(:resolve).never

    processor = PlaidAccount::Investments::TransactionsProcessor.new(@plaid_account, security_resolver: @security_resolver)

    assert_difference [ "Entry.count", "Transaction.count" ], 1 do
      processor.process
    end

    entry = Entry.order(created_at: :desc).first

    assert_equal -100.0, entry.amount
    assert_equal "USD", entry.currency
    assert_equal Date.current, entry.date
    assert_equal "Bank Transfer", entry.name
    assert_instance_of Transaction, entry.entryable
  end

  test "a Plaid cash dividend is labelled Dividend and classified as income" do
    entry = process_plaid_transaction(cash_row("div_1", "dividend", "Dividend AAPL"))

    assert_equal "Dividend", entry.transaction.investment_activity_label
    assert_equal :income, classify(entry)
  end

  test "a qualified dividend is labelled Dividend" do
    entry = process_plaid_transaction(cash_row("qdiv_1", "qualified dividend", "Qualified dividend AAPL"))

    assert_equal "Dividend", entry.transaction.investment_activity_label
  end

  test "a Plaid interest payment is labelled Interest and classified as income" do
    entry = process_plaid_transaction(cash_row("int_1", "interest", "Interest earned"))

    assert_equal "Interest", entry.transaction.investment_activity_label
    assert_equal :income, classify(entry)
  end

  test "a Plaid dividend reinvestment trade is labelled Reinvestment" do
    entry = process_plaid_transaction(trade_row("drip_1", "buy", "dividend reinvestment"))

    assert_equal "Reinvestment", entry.trade.investment_activity_label
    assert_equal :internal, classify(entry)
  end

  test "re-syncing a DRIP stored as Buy relabels it Reinvestment" do
    entry = process_plaid_transaction(trade_row("drip_2", "buy", "dividend reinvestment"))
    entry.trade.update_columns(investment_activity_label: "Buy")

    assert_changes -> { entry.trade.reload.investment_activity_label }, from: "Buy", to: "Reinvestment" do
      PlaidAccount::Investments::TransactionsProcessor.new(@plaid_account, security_resolver: @security_resolver).process
    end
  end

  test "a buy with subtype contribution stays a Buy" do
    entry = process_plaid_transaction(trade_row("buy_contrib_1", "buy", "contribution"))

    assert_equal "Buy", entry.trade.investment_activity_label
    assert_equal :internal, classify(entry)
  end

  test "a cash contribution keeps its label and kind" do
    entry = process_plaid_transaction(cash_row("cash_contrib_1", "contribution", "401k Contribution"))

    assert_equal [ "Other", "standard" ], [ entry.transaction.investment_activity_label, entry.transaction.kind ]

    PlaidAccount::Investments::TransactionsProcessor.new(@plaid_account, security_resolver: @security_resolver).process

    entry.transaction.reload
    assert_equal [ "Other", "standard" ], [ entry.transaction.investment_activity_label, entry.transaction.kind ]
  end

  test "a split under transfer stays Transfer" do
    row = cash_row("split_1", "split", "Stock split")
    row["type"] = "transfer"
    entry = process_plaid_transaction(row)

    assert_equal "Transfer", entry.transaction.investment_activity_label
    assert_equal "funds_movement", entry.transaction.kind
  end

  test "an unmapped subtype falls back to the type" do
    fee = cash_row("fee_2", "miscellaneous fee", "Miscellaneous fee")
    fee["type"] = "fee"
    fee["amount"] = 10.25

    assert_equal "Fee", process_plaid_transaction(fee).transaction.investment_activity_label
    assert_equal "Sell", process_plaid_transaction(trade_row("sell_2", "sell", "sell")).trade.investment_activity_label
  end

  test "a missing subtype falls back to the type" do
    entry = process_plaid_transaction(trade_row("buy_2", "buy", nil))

    assert_equal "Buy", entry.trade.investment_activity_label
  end

  private

    def cash_row(id, subtype, name)
      {
        "investment_transaction_id" => id,
        "type" => "cash",
        "subtype" => subtype,
        "amount" => -12.5, # Negative, so money arriving in the account
        "iso_currency_code" => "USD",
        "date" => Date.current,
        "name" => name
      }
    end

    def trade_row(id, type, subtype)
      sell = type == "sell"
      {
        "investment_transaction_id" => id,
        "security_id" => "123",
        "type" => type,
        "subtype" => subtype,
        "quantity" => sell ? -0.1 : 0.1,
        "price" => 125,
        "amount" => sell ? -12.5 : 12.5,
        "iso_currency_code" => "USD",
        "date" => Date.current,
        "name" => "#{type} AAPL"
      }
    end

    def process_plaid_transaction(row)
      @plaid_account.update!(raw_holdings_payload: { transactions: [ row ] })
      @security_resolver.stubs(:resolve).returns(OpenStruct.new(security: securities(:aapl)))

      PlaidAccount::Investments::TransactionsProcessor.new(@plaid_account, security_resolver: @security_resolver).process

      Entry.find_by!(external_id: row["investment_transaction_id"], source: "plaid")
    end

    def classify(entry)
      Portfolio::FlowClassifier.new(scope_account_ids: [ entry.account_id ]).classify(entry)
    end
end

require "test_helper"

class Provider::Saxo::NormalizerTest < ActiveSupport::TestCase
  setup do
    @normalizer = Provider::Saxo::Normalizer.new(account_id: "123", currency: "EUR")
  end

  test "cash booking signs and corporate action correction identifiers remain stable" do
    first = operation("dividend", "20")
    correction = operation("tax", "-3")
    result = @normalizer.call([ first, first, correction ])
    assert_equal 2, result[:bookings].size
    assert_equal BigDecimal("-20"), result[:bookings]["dividend"][:amount]
    assert_equal BigDecimal("3"), result[:bookings]["tax"][:amount]
  end

  test "cash instruments on cash-only transactions import their bookings" do
    row = operation("deposit", "100").merge("TransactionType" => "CashTransfer",
      "Instrument" => { "AssetType" => "Cash", "Uic" => 1, "Currency" => "EUR" })
    row["Bookings"][0]["AmountType"] = "Deposit"
    result = @normalizer.call([ row ])

    assert_empty result[:trades]
    assert_equal BigDecimal("-100"), result[:bookings]["deposit"][:amount]
    assert_equal "Transfer", result[:bookings]["deposit"][:activity_label]
  end

  test "cash instruments do not allow security movements to be imported as cash" do
    row = trade.merge("Instrument" => { "AssetType" => "Cash", "Uic" => 1, "Currency" => "EUR" })
    assert_raises(Provider::Saxo::Error) { @normalizer.call([ row ]) }

    row["TransactionType"] = "CorporateAction"
    assert_raises(Provider::Saxo::Error) { @normalizer.call([ row ]) }
  end

  test "a buy imports the principal once as a trade and the commission separately" do
    row = trade
    row["Bookings"] << { "BookingId" => "fee", "BookedAmount" => "-2", "AmountType" => "Commission" }
    result = @normalizer.call([ row ])
    assert_equal [ "trade" ], result[:trades].keys
    assert_equal BigDecimal("100"), result[:trades]["trade"][:amount]
    assert_equal [ "fee" ], result[:bookings].keys
    assert_equal "Fee", result[:bookings]["fee"][:activity_label]
  end

  test "trade bookings must reconcile with the row total" do
    row = trade.merge("BookedAmount" => "-101")
    error = assert_raises(Provider::Saxo::Error) { @normalizer.call([ row ]) }
    assert_equal "Saxo cash bookings do not reconcile", error.message
  end

  test "zero-priced foreign security transfers need no exchange rate" do
    row = trade.merge("Event" => "TransferIn", "BookedAmount" => "0", "Bookings" => [])
    row["Trades"][0]["Instrument"]["Currency"] = "USD"
    row["Trades"][0]["Price"] = "0"
    assert_equal 0, @normalizer.call([ row ])[:trades]["trade"][:price]

    row["Trades"][0]["Price"] = "50"
    assert_raises(Provider::Saxo::Error) { @normalizer.call([ row ]) }
  end

  test "an ETC purchase imports its principal as a trade" do
    row = trade
    row["Trades"][0]["Instrument"]["AssetType"] = "Etc"

    result = @normalizer.call([ row ])

    assert_equal "Etc", result[:trades]["trade"][:instrument]["AssetType"]
    assert_equal BigDecimal("2"), result[:trades]["trade"][:quantity]
    assert_equal BigDecimal("100"), result[:trades]["trade"][:amount]
    assert_empty result[:bookings]
  end

  test "a sale has negative quantity and negative cash entry amount" do
    row = trade
    row["Event"] = "Sell"
    row["Trades"][0]["TradedQuantity"] = "-2"
    row["Bookings"][0]["BookedAmount"] = "100"
    result = @normalizer.call([ row ])[:trades]["trade"]
    assert_equal BigDecimal("-2"), result[:quantity]
    assert_equal BigDecimal("-100"), result[:amount]
  end

  test "a trade reversal keeps its signed security and cash movements" do
    row = trade.merge("IsReversal" => true)
    row["Trades"][0]["TradedQuantity"] = "-2"
    row["Bookings"][0]["BookedAmount"] = "100"
    result = @normalizer.call([ row ])[:trades]["trade"]
    assert_equal BigDecimal("-2"), result[:quantity]
    assert_equal BigDecimal("-100"), result[:amount]
    assert_equal "Sell", result[:activity_label]
  end

  test "security transfers without cash retain their direction and transfer label" do
    [ [ "Transfer In", "2" ], [ "TransferIn", "2" ], [ "Transfer Out", "-2" ], [ "TransferOut", "-2" ] ].each do |event, quantity|
      row = trade.merge("Event" => event, "BookedAmount" => "0", "Bookings" => [])
      row["Trades"][0]["TradedQuantity"] = quantity

      result = @normalizer.call([ row ])
      assert_empty result[:bookings]
      assert_equal BigDecimal(quantity), result[:trades]["trade"][:quantity]
      assert_equal 0, result[:trades]["trade"][:amount]
      assert_equal "Transfer", result[:trades]["trade"][:activity_label]
    end
  end

  test "security transfers still reject a mismatched movement direction" do
    row = trade.merge("Event" => "Transfer In", "BookedAmount" => "0", "Bookings" => [])
    row["Trades"][0]["TradedQuantity"] = "-2"
    assert_raises(Provider::Saxo::Error) { @normalizer.call([ row ]) }
  end

  test "inconsistent principal and security directions abort" do
    row = trade
    row["Bookings"][0]["BookedAmount"] = "100"
    assert_raises(Provider::Saxo::Error) { @normalizer.call([ row ]) }
  end

  test "unsupported trade diagnostics describe the event and booking types without financial data" do
    row = trade
    row["Event"] = "Sell"
    row["Bookings"][0]["AmountType"] = "Cash Settlement"
    row["Trades"][0]["TradeEventType"] = "Sold"
    row["Trades"][0]["Instrument"]["Symbol"] = "private-symbol"

    error = assert_raises(Provider::Saxo::Error) { @normalizer.call([ row ]) }
    assert_equal({ stage: "history", reason: "unsupported_trade", event: "Sell", trade_event_type: "Sold",
      booking_types: [ "Cash Settlement" ], booking_count: 1, principal_count: 0,
      quantity_direction: "positive" }, error.diagnostic)
    assert_no_match(/private-symbol|123|100/, error.diagnostic.inspect)
  end

  test "unrecognized trade events are included in sanitized diagnostics" do
    row = trade.merge("Event" => "UnrecognizedEvent")
    row["Bookings"][0]["AmountType"] = "identifier-123"

    error = assert_raises(Provider::Saxo::Error) { @normalizer.call([ row ]) }
    assert_equal "UnrecognizedEvent", error.diagnostic[:event]
    assert_equal [ nil ], error.diagnostic[:booking_types]
  end

  test "explicit FX is retained and missing FX aborts" do
    row = trade
    row["Trades"][0]["Instrument"]["Currency"] = "USD"
    assert_raises(Provider::Saxo::Error) { @normalizer.call([ row ]) }
    row["Bookings"][0]["ConversionRate"] = "0.92"
    assert_equal BigDecimal("0.92"), @normalizer.call([ row ])[:trades]["trade"][:conversion_rate]
  end

  test "client currency bookings use the explicit account to client conversion" do
    row = operation("one", "11.04").merge("Currency" => "USD")
    row["Bookings"][0]["ConversionRateAccountToClientCurrency"] = "0.92"
    result = @normalizer.call([ row ])[:bookings]["one"]
    assert_equal BigDecimal("-12"), result[:amount]
    assert_equal "EUR", result[:currency]
    assert_equal "USD", result[:extra]["saxo"]["source_currency"]
  end

  test "intraday entries are excluded" do
    assert_empty @normalizer.call([ operation.merge("IsIntradayData" => true) ])[:bookings]
  end

  test "invalid amounts identifiers currencies and foreign accounts abort" do
    [ operation.merge("AccountId" => "other"), operation.merge("Currency" => "USD"),
      operation(nil), operation("one", "NaN"), operation.merge("Date" => "invalid") ].each do |row|
      assert_raises(Provider::Saxo::Error) { @normalizer.call([ row ]) }
    end
  end

  test "conflicting repeated IDs abort" do
    assert_raises(Provider::Saxo::Error) { @normalizer.call([ operation, operation("one", "9") ]) }
  end

  test "unsupported instruments never become ordinary expenses" do
    row = trade
    row["Trades"][0]["Instrument"]["AssetType"] = "CfdOnStock"
    error = assert_raises(Provider::Saxo::Error) { @normalizer.call([ row ]) }
    assert_equal({ stage: "history", location: "trade", asset_type: "CfdOnStock", uic_present: true, currency_valid: true }, error.diagnostic)
  end

  test "incomplete instruments report which required fields are invalid" do
    row = trade
    row["Instrument"] = { "AssetType" => "Stock", "Symbol" => "private-symbol" }

    error = assert_raises(Provider::Saxo::Error) { @normalizer.call([ row ]) }
    assert_equal({ stage: "history", location: "transaction", asset_type: "Stock", uic_present: false, currency_valid: false }, error.diagnostic)
    assert_no_match "private-symbol", error.diagnostic.inspect
  end

  private
    def operation(id = "one", amount = "12")
      { "AccountId" => "123", "Currency" => "EUR", "Date" => "2026-10-20", "TransactionType" => "CorporateAction",
        "Bookings" => [ { "BookingId" => id, "BookedAmount" => amount, "AmountType" => "Dividend" } ] }
    end

    def trade
      operation.merge("TransactionType" => "Trade", "Event" => "Buy",
        "Bookings" => [ { "BookingId" => "principal", "BookedAmount" => "-100", "AmountType" => "Share Amount" } ],
        "Trades" => [ { "TradeId" => "trade", "TradedQuantity" => "2", "Price" => "50",
          "Instrument" => { "Uic" => 100, "AssetType" => "Stock", "Symbol" => "EXAMPLE", "Currency" => "EUR" } } ])
    end
end

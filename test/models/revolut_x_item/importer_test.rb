# frozen_string_literal: true

require "test_helper"

class RevolutXItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @item = families(:dylan_family).revolut_x_items.create!(name: "Revolut X", api_key: "a1" * 32)
    @provider = mock
    @provider.stubs(:get_balances).returns(payload("balances"))
    @provider.stubs(:get_sub_accounts).returns(payload("sub_accounts"))
    @provider.stubs(:get_currencies).returns(
      payload("currencies").merge("USD" => { "symbol" => "USD", "name" => "US Dollar", "scale" => 2, "asset_type" => "fiat", "status" => "active" })
    )
    @tickers = payload("tickers")
    @tickers["data"] << { "symbol" => "ETH/USD", "mid" => "3000.00", "last_price" => "2999.00" }
    @provider.stubs(:get_tickers).returns(@tickers)
    @provider.stubs(:get_transactions).returns(transactions_page([]))
  end

  test "stores one USD account valued from balances and tickers" do
    assert_difference -> { @item.revolut_x_accounts.count }, 1 do
      import
    end

    account = @item.revolut_x_accounts.sole
    assert_equal "default", account.account_id
    assert_equal "exchange", account.account_type
    assert_equal "USD", account.currency
    assert_equal "Revolut X", account.name
    assert_equal (1.35.to_d * 120_000) + (42 * 3000) + 5500.50.to_d, account.current_balance

    @item.reload
    assert_equal payload("balances"), @item.raw_payload["balances"]
    assert_equal payload("sub_accounts").dig("data", "sub_accounts"), @item.raw_payload["sub_accounts"]
    assert_equal "fiat", @item.raw_payload.dig("currencies", "USD", "asset_type")
  end

  test "a second import updates the same account" do
    import
    @provider.stubs(:get_balances).returns([ { "currency" => "USD", "total" => "10" } ])

    assert_no_difference -> { @item.revolut_x_accounts.count } do
      import
    end
    assert_equal 10, @item.revolut_x_accounts.sole.current_balance
  end

  test "falls back to last_price, then to a EUR or GBP pair converted to USD" do
    @tickers["data"] = [
      { "symbol" => "BTC/USD", "mid" => "", "last_price" => "100000.00" },
      { "symbol" => "ETH/GBP", "mid" => "2000.00" }
    ]
    ExchangeRate.create!(from_currency: "GBP", to_currency: "USD", date: Date.current, rate: 1.25)

    import

    assets = @item.revolut_x_accounts.sole.raw_payload["assets"].index_by { |asset| asset["symbol"] }
    assert_equal "100000.0", assets["BTC"]["price_usd"]
    assert_equal "2500.0", assets["ETH"]["price_usd"]
  end

  test "a balance in an ISO fiat Revolut X does not list, like CZK, is cash" do
    @provider.stubs(:get_balances).returns(payload("balances") + [ { "currency" => "CZK", "total" => "1000.00" } ])
    ExchangeRate.create!(from_currency: "CZK", to_currency: "USD", date: Date.current, rate: 0.04)

    import

    account = @item.revolut_x_accounts.sole
    czk = account.raw_payload["assets"].find { |asset| asset["symbol"] == "CZK" }
    assert_equal "fiat", czk["kind"]
    assert_equal "0.04", czk["price_usd"]
    assert_equal "40.0", czk["amount_usd"]
    assert_equal (1.35.to_d * 120_000) + (42 * 3000) + 5500.50.to_d + 40, account.current_balance
  end

  test "keeps an unpriced asset with no price and no value" do
    @tickers["data"].reject! { |ticker| ticker["symbol"].start_with?("ETH/") }

    import

    account = @item.revolut_x_accounts.sole
    eth = account.raw_payload["assets"].find { |asset| asset["symbol"] == "ETH" }
    assert_nil eth["price_usd"]
    assert_equal (1.35.to_d * 120_000) + 5500.50.to_d, account.current_balance
  end

  # 2025-03-01T00:00:00Z, and 2024-12-01T00:00:00Z: the oldest sub-account in sub_accounts.json.
  NOW_MS = 1_740_787_200_000
  FLOOR_MS = 1_733_011_200_000
  WINDOW_MS = 2_592_000_000

  test "first sync walks back from now to the oldest sub-account in 30-day windows" do
    windows = record_windows

    travel_to(Time.at(NOW_MS / 1000).utc) { import }

    assert_equal [
      [ NOW_MS - WINDOW_MS, NOW_MS ],
      [ NOW_MS - 2 * WINDOW_MS, NOW_MS - WINDOW_MS ],
      [ FLOOR_MS, NOW_MS - 2 * WINDOW_MS ]
    ], windows
    assert windows.each_cons(2).all? { |newer, older| older[1] == newer[0] }
    assert windows.all? { |from, to| to - from <= WINDOW_MS }
    assert_equal Time.at(NOW_MS / 1000).utc, @item.reload.transactions_synced_through
  end

  test "a later sync_start_date raises the history floor" do
    @item.update!(sync_start_date: Time.utc(2025, 2, 1))
    windows = record_windows

    travel_to(Time.at(NOW_MS / 1000).utc) { import }

    assert_equal [ [ Time.utc(2025, 2, 1).to_i * 1000, NOW_MS ] ], windows
  end

  test "follows next_cursor within a window, always asking for 1900 rows" do
    calls = []
    @provider.stubs(:get_transactions).with do |**args|
      calls << args
      true
    end.returns(transactions_page([ row("t1") ], next_cursor: "c1"), transactions_page([ row("t2") ], next_cursor: ""))
    @item.update!(sync_start_date: 10.days.ago)

    import

    assert_equal 2, calls.size
    assert_nil calls.first[:cursor]
    assert_equal "c1", calls.second[:cursor]
    assert calls.all? { |args| args[:limit] == 1900 }
    assert_equal %w[t1 t2], stored_transactions.keys.sort
  end

  test "a repeated cursor aborts the walk without advancing it" do
    @provider.stubs(:get_transactions).returns(transactions_page([ row("t1") ], next_cursor: "c1"))

    assert_difference -> { DebugLogEntry.where(provider_key: "revolut_x").count }, 1 do
      import
    end

    assert_nil @item.reload.transactions_synced_through
    assert_equal %w[t1], stored_transactions.keys
  end

  test "a later sync starts 3 days before the last completed walk" do
    synced_through = Time.utc(2025, 2, 20)
    @item.update!(transactions_synced_through: synced_through)
    windows = record_windows

    travel_to(Time.at(NOW_MS / 1000).utc) { import }

    assert_equal [ [ (synced_through - 3.days).to_i * 1000, NOW_MS ] ], windows
  end

  test "a later sync reaches back to the oldest stored pending row" do
    synced_through = Time.utc(2025, 2, 20)
    pending_at = ((synced_through - 3.days - 10.days).to_i * 1000)
    @item.update!(transactions_synced_through: synced_through)
    import
    @item.revolut_x_accounts.sole.update!(raw_transactions_payload: {
      "transactions" => { "p1" => row("p1", status: "pending", created_date: pending_at) }
    })
    windows = record_windows

    travel_to(Time.at(NOW_MS / 1000).utc) { import }

    assert_equal pending_at, windows.last.first
  end

  test "a rate limit mid-walk keeps fetched rows, does not advance, and the balances still import" do
    @provider.stubs(:get_transactions)
      .returns(transactions_page([ row("t1") ]))
      .then.raises(Provider::RevolutX::RateLimitError, "Revolut X rate limit exceeded")

    result = nil
    assert_difference -> { DebugLogEntry.where(provider_key: "revolut_x").count }, 1 do
      result = travel_to(Time.at(NOW_MS / 1000).utc) { import }
    end

    assert result[:success]
    assert @item.revolut_x_accounts.sole.current_balance.positive?
    assert_nil @item.reload.transactions_synced_through
    assert_equal %w[t1], stored_transactions.keys
  end

  test "a network error mid-walk keeps fetched rows, does not advance, and the balances still import" do
    @provider.stubs(:get_transactions)
      .returns(transactions_page([ row("t1") ]))
      .then.raises(EOFError)

    result = nil
    assert_difference -> { DebugLogEntry.where(provider_key: "revolut_x").count }, 1 do
      result = travel_to(Time.at(NOW_MS / 1000).utc) { import }
    end

    assert result[:success]
    assert_nil @item.reload.transactions_synced_through
    assert_equal %w[t1], stored_transactions.keys
  end

  test "rows merge by id, a newer copy replacing the stored one" do
    @provider.stubs(:get_transactions).returns(transactions_page([ row("t1", status: "pending"), row("t2") ]))
    import
    @provider.stubs(:get_transactions).returns(transactions_page([ row("t1", status: "completed") ]))

    import

    assert_equal %w[t1 t2], stored_transactions.keys.sort
    assert_equal "completed", stored_transactions["t1"]["status"]
  end

  test "authentication errors propagate" do
    @provider.stubs(:get_transactions).raises(Provider::RevolutX::AuthenticationError, "bad key")

    assert_raises(Provider::RevolutX::AuthenticationError) { import }
  end

  test "a malformed transactions page does not advance the walk and is logged" do
    synced_through = Time.utc(2025, 2, 20)
    @item.update!(transactions_synced_through: synced_through)
    [ { "metadata" => {} }, transactions_page([ { "status" => "completed" } ]) ].each do |page|
      @provider.stubs(:get_transactions).returns(page)

      assert_difference -> { DebugLogEntry.where(provider_key: "revolut_x").count }, 1 do
        travel_to(Time.at(NOW_MS / 1000).utc) { import }
      end

      assert_equal synced_through, @item.reload.transactions_synced_through
      assert_match "malformed transactions page", DebugLogEntry.where(provider_key: "revolut_x").order(:created_at).last.message
    end
  end

  test "a balance total that is missing or not a number fails the import and keeps the stored assets" do
    import
    assets = @item.revolut_x_accounts.sole.raw_payload["assets"]

    [ nil, "abc" ].each do |total|
      @provider.stubs(:get_balances).returns([ { "currency" => "BTC", "total" => total } ])

      assert_raises(Provider::RevolutX::ApiError) { import }
      assert_equal assets, @item.revolut_x_accounts.sole.reload.raw_payload["assets"]
    end
  end

  test "a cut walk in the same second as a complete one is not taken as complete" do
    complete_at = Time.utc(2025, 3, 1, 0, 0, 0.2r)
    travel_to(complete_at, with_usec: true) { import }

    @provider.stubs(:get_transactions).raises(Provider::RevolutX::RateLimitError, "Revolut X rate limit exceeded")
    travel_to(complete_at + 0.5, with_usec: true) { import }

    revolut_x_account = @item.revolut_x_accounts.sole.reload
    assert_equal complete_at, @item.reload.transactions_synced_through
    assert_equal complete_at + 0.5, Time.iso8601(revolut_x_account.raw_transactions_payload["fetched_at"])
    assert_not RevolutXAccount::TransactionsProcessor.new(revolut_x_account).send(:history_complete?)
  end

  test "an import older than the stored history leaves it untouched" do
    @provider.stubs(:get_transactions).returns(transactions_page([ row("t1") ]))
    travel_to(Time.at(NOW_MS / 1000).utc) { import }
    newer = { "transactions" => { "t9" => row("t9") }, "fetched_at" => Time.at(NOW_MS / 1000 + 60).utc.iso8601(6) }
    @item.revolut_x_accounts.sole.update!(raw_transactions_payload: newer)
    synced_through = @item.reload.transactions_synced_through

    travel_to(Time.at(NOW_MS / 1000 + 30).utc) { import }

    assert_equal newer, @item.revolut_x_accounts.sole.reload.raw_transactions_payload
    assert_equal synced_through, @item.reload.transactions_synced_through
  end

  private

    def import
      RevolutXItem::Importer.new(@item, revolut_x_provider: @provider).import
    end

    def record_windows
      windows = []
      @provider.stubs(:get_transactions).with do |start_date:, end_date:, **|
        windows << [ start_date, end_date ]
        true
      end.returns(transactions_page([]))
      windows
    end

    def stored_transactions
      @item.revolut_x_accounts.sole.reload.raw_transactions_payload["transactions"]
    end

    def row(id, status: "completed", created_date: NOW_MS - 1000)
      {
        "id" => id, "status" => status, "type" => "reward", "created_date" => created_date,
        "destination" => { "amount" => "1", "currency" => "ETH", "account" => { "type" => "revolut_x" } }
      }
    end

    def transactions_page(rows, next_cursor: nil)
      { "data" => rows, "metadata" => { "timestamp" => NOW_MS, "next_cursor" => next_cursor } }
    end

    def payload(name)
      JSON.parse(file_fixture("revolut_x/#{name}.json").read)
    end
end

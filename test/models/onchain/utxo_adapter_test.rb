# frozen_string_literal: true

require "test_helper"

class Onchain::UtxoAdapterTest < ActiveSupport::TestCase
  LTC_P2PKH = "LU2ztpZDcP7xwEzwJiRSHPGWToHQggwacr"
  LTC_P2SH = "MQd1fJwqBJvwLuyhr17PhEFx1swiqDbPQS"
  LTC_BECH32 = "ltc1qr07zu594qf63xm7l7x6pu3a2v39m2z6hh5pp4t"
  DOGE = "DH5yaieqoZN36fDVciNyRueRGvGLR3mr7L"
  ZEC_P2PKH = "t1RyCw14wRXrh3mp21uxgr9ynjem7cNUkMH"
  ZEC_P2SH = "t3aPMe94jMKyrgkbH5SSukimvdMFJ59EFhP"

  setup do
    @previous_key = ENV.delete("SOCHAIN_API_KEY")
    @litecoin = Onchain::Chains.adapter_for("litecoin")
    @dogecoin = Onchain::Chains.adapter_for("dogecoin")
    @zcash = Onchain::Chains.adapter_for("zcash")
  end

  teardown do
    ENV["SOCHAIN_API_KEY"] = @previous_key
  end

  test "registers Litecoin, Dogecoin and Zcash with eight-decimal native coins" do
    { "litecoin" => "LTC", "dogecoin" => "DOGE", "zcash" => "ZEC" }.each do |key, symbol|
      definition = Onchain::Chains.find!(key)

      assert_equal symbol, definition.native.symbol
      assert_equal 8, definition.native.decimals
      assert_not definition.supports_tokens?
    end
  end

  test "accepts each chain's address formats" do
    [ LTC_P2PKH, LTC_P2SH, LTC_BECH32 ].each { |address| assert @litecoin.valid_address?(address), address }
    assert @dogecoin.valid_address?(DOGE)
    [ ZEC_P2PKH, ZEC_P2SH ].each { |address| assert @zcash.valid_address?(address), address }
  end

  test "rejects other chains' addresses without making a network call" do
    # WebMock raises on any unstubbed request, so a network call here fails the test.
    assert_not @litecoin.valid_address?("bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq")
    assert_not @litecoin.valid_address?(DOGE)
    assert_not @dogecoin.valid_address?(LTC_P2PKH)
    assert_not @dogecoin.valid_address?("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045")
    # Shielded and unified Zcash addresses carry no visible balance.
    assert_not @zcash.valid_address?("zs1z7rejlpsa98s2rrrfkwmaxu53e4ue0ulcrw0h4x5g8jl04tak0d3mm47vdtahatqrlkngh9sly")
    assert_not @zcash.valid_address?("t1RyCw14wRXrh3mp21uxgr9ynjem7cNUkM0")
    assert_not @zcash.valid_address?("")
  end

  test "shared address shapes leave the choice to detection" do
    # Litecoin's legacy script addresses look like Bitcoin's, and every Base58
    # address fits Solana's shape.
    assert_includes Onchain::Chains.matching("3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy").map(&:key), "litecoin"
    assert_equal %w[dogecoin solana], Onchain::Chains.matching(DOGE).map(&:key).sort
    assert_equal %w[litecoin], Onchain::Chains.matching(LTC_BECH32).map(&:key)
  end

  test "bech32 is canonically lowercase while Base58 keeps its case" do
    assert_equal LTC_BECH32, @litecoin.canonical_address(" #{LTC_BECH32.upcase} ")
    assert_equal LTC_P2PKH, @litecoin.canonical_address(LTC_P2PKH)
  end

  test "balance is confirmed plus the pending change, in exact decimals" do
    stub_balance("DOGE", DOGE, confirmed: "1000.12345678", unconfirmed: "-0.00000001")
    stub_transactions("DOGE", DOGE, 1, [])

    asset = @dogecoin.fetch_snapshot(DOGE).assets.sole

    assert asset.native?
    assert_equal "DOGE", asset.symbol
    assert_equal BigDecimal("1000.12345677"), asset.quantity
  end

  test "movements are each transaction's balance change" do
    stub_balance("LTC", LTC_P2PKH)
    stub_transactions("LTC", LTC_P2PKH, 1, [
      transaction("pending", "0.10000000", block: nil, time: Time.utc(2026, 1, 4)),
      transaction("spent", "-0.16000000", block: 3_000_001, time: Time.utc(2026, 1, 3)),
      transaction("received", "0.20000001", block: 3_000_000, time: Time.utc(2026, 1, 2))
    ])

    movements = @litecoin.fetch_snapshot(LTC_P2PKH).movements

    assert_equal %w[pending spent received], movements.map(&:external_id)
    assert_equal [ BigDecimal("0.1"), BigDecimal("-0.16"), BigDecimal("0.20000001") ], movements.map(&:amount)
    assert_equal [ Date.current, Date.new(2026, 1, 3), Date.new(2026, 1, 2) ], movements.map(&:date)
    assert movements.all? { |movement| movement.symbol == "LTC" && movement.contract.nil? }
  end

  test "a transaction that leaves the balance unchanged produces no movement" do
    stub_balance("ZEC", ZEC_P2PKH)
    stub_transactions("ZEC", ZEC_P2PKH, 1, [ transaction("unchanged", "0.00000000") ])

    assert_empty @zcash.fetch_snapshot(ZEC_P2PKH).movements
  end

  test "history is read page by page until a short page" do
    stub_balance("DOGE", DOGE)
    stub_transactions("DOGE", DOGE, 1, full_page("a"))
    stub_transactions("DOGE", DOGE, 2, [ transaction("b0", "1.00000000") ])

    snapshot = @dogecoin.fetch_snapshot(DOGE)

    assert_equal Provider::Sochain::PAGE_SIZE + 1, snapshot.movements.size
    assert_not snapshot.history_truncated?
  end

  test "a history longer than the budget is reported as truncated" do
    stub_balance("DOGE", DOGE, confirmed: "5.00000000")
    stub_transactions("DOGE", DOGE, 1, full_page("a"))
    stub_transactions("DOGE", DOGE, 2, full_page("b"))

    with_history_budget(2) do
      snapshot = @dogecoin.fetch_snapshot(DOGE)

      assert snapshot.history_truncated?
      assert_equal 2 * Provider::Sochain::PAGE_SIZE, snapshot.movements.size
      # Balances come from their own request, so the cap does not touch them.
      assert_equal BigDecimal("5"), snapshot.assets.sole.quantity
    end
  end

  test "a source that refuses history still yields the balance" do
    Provider::Sochain.any_instance.stubs(:sleep)
    stub_balance("LTC", LTC_P2PKH, confirmed: "1.00000000")
    stub_request(:get, "#{base_url}/transactions/LTC/#{LTC_P2PKH}/1").to_return(status: 429)

    snapshot = @litecoin.fetch_snapshot(LTC_P2PKH)

    assert_equal BigDecimal("1"), snapshot.assets.sole.quantity
    assert_empty snapshot.movements
    assert snapshot.history_truncated?
  end

  test "a long Retry-After fails at once instead of holding the sync" do
    stub_request(:get, "#{base_url}/balance/LTC/#{LTC_P2PKH}")
      .to_return(status: 429, headers: { "Retry-After" => "3600" })

    Provider::Sochain.any_instance.expects(:sleep).never

    assert_raises Onchain::Chains::RateLimitedError do
      @litecoin.fetch_snapshot(LTC_P2PKH)
    end
  end

  test "a short Retry-After is waited out" do
    stub_request(:get, "#{base_url}/balance/LTC/#{LTC_P2PKH}")
      .to_return({ status: 429, headers: { "Retry-After" => "2" } }, balance_response("0.50000000"))
    stub_transactions("LTC", LTC_P2PKH, 1, [])

    # Pacing between requests sleeps too; only the wait asked for is checked.
    Provider::Sochain.any_instance.stubs(:sleep)
    Provider::Sochain.any_instance.expects(:sleep).with(2).once

    assert_equal BigDecimal("0.5"), @litecoin.fetch_snapshot(LTC_P2PKH).assets.sole.quantity
  end

  test "a timed-out source is reported as unreachable" do
    stub_request(:get, "#{base_url}/balance/ZEC/#{ZEC_P2SH}").to_timeout

    assert_raises Onchain::Chains::UnreachableError do
      @zcash.fetch_snapshot(ZEC_P2SH)
    end
  end

  test "a rejected key is reported as unreachable with its reason" do
    stub_request(:get, "#{base_url}/balance/ZEC/#{ZEC_P2SH}").to_return(status: 401)

    error = assert_raises Onchain::Chains::UnreachableError do
      @zcash.fetch_snapshot(ZEC_P2SH)
    end
    assert_match "API key", error.message
  end

  test "sends no key by default" do
    request = stub_balance("ZEC", ZEC_P2SH)
    stub_transactions("ZEC", ZEC_P2SH, 1, [])

    @zcash.fetch_snapshot(ZEC_P2SH)

    assert_requested request
    assert_not_requested(:get, "#{base_url}/balance/ZEC/#{ZEC_P2SH}", headers: { "API-KEY" => /.*/ })
  end

  test "sends the family's key as API-KEY" do
    request = stub_balance("ZEC", ZEC_P2SH).with(headers: { "API-KEY" => "family-key" })
    stub_transactions("ZEC", ZEC_P2SH, 1, [])

    Onchain::Chains.adapter_for("zcash", credentials: { sochain_api_key: "family-key" }).fetch_snapshot(ZEC_P2SH)

    assert_requested request
  end

  test "falls back to SOCHAIN_API_KEY when the family has no key" do
    ENV["SOCHAIN_API_KEY"] = "instance-key"
    request = stub_balance("ZEC", ZEC_P2SH).with(headers: { "API-KEY" => "instance-key" })
    stub_transactions("ZEC", ZEC_P2SH, 1, [])

    Onchain::Chains.adapter_for("zcash", credentials: { sochain_api_key: nil }).fetch_snapshot(ZEC_P2SH)

    assert_requested request
  end

  test "activity is one transaction-count request" do
    stub_request(:get, "#{base_url}/transaction_counts/LTC/#{LTC_P2SH}")
      .to_return(json({ "sent" => 0, "received" => 2, "total" => 2 }))

    assert @litecoin.has_activity?(LTC_P2SH)
  end

  test "an unused address has no activity" do
    stub_request(:get, "#{base_url}/transaction_counts/LTC/#{LTC_P2SH}")
      .to_return(json({ "sent" => 0, "received" => 0, "total" => 0 }))

    assert_equal false, @litecoin.has_activity?(LTC_P2SH)
  end

  test "a failed activity probe could not tell, rather than saying no" do
    stub_request(:get, "#{base_url}/transaction_counts/LTC/#{LTC_P2SH}").to_return(status: 503)

    assert_nil @litecoin.has_activity?(LTC_P2SH)
  end

  test "fetch_snapshot refuses a malformed address before any request" do
    assert_raises Onchain::Chains::Error do
      @dogecoin.fetch_snapshot("not-an-address")
    end
  end

  private
    def base_url
      Provider::Sochain.base_url
    end

    def with_history_budget(pages)
      previous = ENV["ONCHAIN_HISTORY_MAX_PAGES"]
      ENV["ONCHAIN_HISTORY_MAX_PAGES"] = pages.to_s
      yield
    ensure
      ENV["ONCHAIN_HISTORY_MAX_PAGES"] = previous
    end

    def json(data)
      { status: 200, body: { "status" => "success", "data" => data }.to_json, headers: { "Content-Type" => "application/json" } }
    end

    def balance_response(confirmed, unconfirmed = "0.00000000")
      json({ "confirmed" => confirmed, "unconfirmed" => unconfirmed })
    end

    def stub_balance(network, address, confirmed: "0.00000000", unconfirmed: "0.00000000")
      stub_request(:get, "#{base_url}/balance/#{network}/#{address}").to_return(balance_response(confirmed, unconfirmed))
    end

    def stub_transactions(network, address, page, transactions)
      stub_request(:get, "#{base_url}/transactions/#{network}/#{address}/#{page}")
        .to_return(json({ "transactions" => transactions }))
    end

    def transaction(hash, balance_change, block: 1, time: Time.utc(2026, 1, 2))
      sent = balance_change.start_with?("-") ? balance_change.delete_prefix("-") : "0.00000000"
      received = balance_change.start_with?("-") ? "0.00000000" : balance_change

      {
        "hash" => hash,
        "value_sent" => sent,
        "value_received" => received,
        "balance_change" => balance_change,
        "time" => time.to_i,
        "block" => block,
        "price" => nil
      }
    end

    def full_page(prefix)
      Array.new(Provider::Sochain::PAGE_SIZE) { |i| transaction("#{prefix}#{i}", "0.00000001") }
    end
end

require "test_helper"

class Provider::AccountData::OnchainWalletTest < ActiveSupport::TestCase
  setup do
    @observed_at = Time.utc(2026, 5, 9, 12)
    @descriptor = { "version" => 1, "chain" => "bitcoin", "asset_kind" => "native", "wallet_address" => "1BoatSLRHtKNngkdXEeobR76b53LETtpyT",
      "contract_address" => nil, "symbol" => "BTC", "name" => "Bitcoin", "decimals" => 8, "ingestion_namespace" => "onchain_legacy-source-uuid" }
    @external_id = Provider::AccountData::OnchainWallet::SourceDescriptor.external_id(@descriptor)
    @asset = Onchain::Asset.native(symbol: "BTC", name: "Bitcoin", decimals: 8, quantity: BigDecimal("2"))
    @movements = [ movement("received", "0.5"), movement("sent", "-0.125") ]
    @snapshot = archive
    @external = external
    @adapter = adapter
    @account = @adapter.list_accounts.records.sole
  end

  test "factory requires current capture context performs no HTTP and remains gated" do
    Provider::AccountData::OnchainWallet::Client.any_instance.expects(:read).never
    configuration = Provider::AccountData::OnchainWallet::Configuration.build
    built = Provider::AccountData::OnchainWallet.build(credentials: {}, settings: {}, context: { external_accounts: [ @external ],
      timezone: "UTC", observed_at: @observed_at.freeze, family_locale: "en", connection_details: { sync_start_date: "2026-05-09" },
      onchain_configuration: configuration, onchain_fx_credentials: Provider::AccountData::OnchainWallet::FxConfiguration.credentials,
      onchain_capture: { "scope" => { "family_id" => "family", "connection_id" => "connection",
        "sync_id" => "sync", "observed_at" => @observed_at.iso8601(9) }, "input_sha256" => nil, "fragments" => [] } })
    assert_not Provider::AccountData::OnchainWallet.native_ready?
    assert_equal %w[holdings activities], built.capabilities
    assert_raises(Provider::AccountData::IncompletePage) { built.fetch_balance(account: @account) }
  end

  test "inventory includes only selected assets and never treats explorer discoveries as tracked" do
    # An entirely different selected address has a different inventory identity;
    # an explorer snapshot is not itself an instruction to select it.
    page = @adapter.list_accounts
    assert page.complete?
    assert_equal @external_id, page.records.sole[:external_id]
    assert_equal "Crypto", page.records.sole[:account_type]
    assert_nil page.records.sole[:balance]
    assert_equal false, page.records.sole[:metadata][:balance_provided]
    assert_equal "user_selected_assets", page.coverage["scope"]
    assert_equal false, page.coverage["absence_authoritative"]
    assert_not_includes page.records.sole[:metadata].inspect, @descriptor["wallet_address"]
  end

  test "balance and holding use same captured quantity price and legacy identity" do
    balance = @adapter.fetch_balance(account: @account)
    holding = @adapter.fetch_holdings(account: @account)
    assert balance.complete?
    assert holding.complete?
    assert_equal BigDecimal("100000"), balance.records.sole[:balance]
    assert_equal BigDecimal("0"), balance.records.sole[:cash_balance]
    assert_equal "2.0", balance.records.sole[:metadata][:asset][:quantity]
    assert_equal "onchain_legacy-source-uuid", holding.records.sole[:external_id]
    assert_equal BigDecimal("2"), holding.records.sole[:quantity]
    assert_equal BigDecimal("50000"), holding.records.sole[:price]
    assert_equal({ lookup: "onchain_asset", ticker: "CRYPTO:BTC", symbol: "BTC", name: "Bitcoin" }, holding.records.sole[:security])
    assert_equal false, holding.coverage["absence_authoritative"]
    assert_equal Provider::AccountData::OnchainWallet::SnapshotArchive.new(@snapshot).fingerprint, balance.evidence["snapshot_sha256"]
    assert_equal "2.0", balance.evidence["asset"]["quantity"]
  end

  test "movements retain transfer labels signed quantities exact historical prices and four place amounts" do
    page = @adapter.fetch_activities(account: @account)
    assert page.complete?
    received, sent = page.records
    assert_equal "onchain_legacy-source-uuid_received", received[:external_id]
    assert_equal "onchain_legacy-source-uuid_sent", sent[:external_id]
    assert_equal BigDecimal("0.5"), received[:quantity]
    assert_equal BigDecimal("-20000"), received[:amount]
    assert_equal BigDecimal("-0.125"), sent[:quantity]
    assert_equal BigDecimal("5000"), sent[:amount]
    page.records.each do |record|
      assert_equal "trade", record.ledger_type
      assert_equal "transfer", record[:activity_type]
      assert_equal "Transfer", record[:metadata][:investment_activity_label]
      assert_equal BigDecimal("40000"), record[:price]
      assert_equal Date.new(2026, 5, 8), record[:date]
    end
    assert_equal I18n.t("onchain_wallet_item.movement.received", locale: "en", quantity: "0.5", symbol: "BTC"), received[:name]
    assert_equal false, page.coverage["pending_absence_authoritative"]
    restored = Ingestion::Codec.load(Ingestion::Codec.dump(page))
    assert_equal received[:quantity], restored.records.first[:quantity]
    assert_equal page.evidence["snapshot_sha256"], restored.evidence["snapshot_sha256"]
  end

  test "unpriced positions do not overwrite valuation and unpriced movements remain quarantined" do
    data = external(prices: prices(current: nil, historical: {}))
    built = adapter(external_accounts: [ data ])
    balance = built.fetch_balance(account: @account)
    assert_not balance.complete?
    assert_nil balance.records.sole[:balance]
    assert_equal "2.0", balance.records.sole[:metadata][:asset][:quantity]
    assert_empty built.fetch_holdings(account: @account).records
    movements = built.fetch_activities(account: @account)
    assert_not movements.complete?
    assert_empty movements.records
    assert_equal [ "movement_price_unavailable" ], movements.warnings.map { |row| row["code"] }.uniq
    assert_equal 2, movements.evidence["movements"].size
  end

  test "a partial asset inventory cannot zero a selected token that was not observed" do
    snapshot = archive(assets: [], assets_truncated: true)
    built = adapter(external_accounts: [ external(snapshot: snapshot, prices: nil) ])
    balance = built.fetch_balance(account: @account)
    assert_not balance.complete?
    assert_nil balance.records.sole[:balance]
    assert_nil balance.records.sole[:metadata][:asset][:quantity]
    assert_empty built.fetch_holdings(account: @account).records
  end

  test "complete absence reports a known zero without inventing a price" do
    snapshot = archive(assets: [], movements: [])
    built = adapter(external_accounts: [ external(snapshot: snapshot, prices: nil) ])
    balance = built.fetch_balance(account: @account)
    assert balance.complete?
    assert_equal BigDecimal("0"), balance.records.sole[:balance]
    assert_equal BigDecimal("0"), built.fetch_holdings(account: @account).records.sole[:quantity]
  end

  test "missing stale or wrong-wallet snapshots cannot be used for current valuation" do
    [ nil, @snapshot.merge("observed_at" => (@observed_at - 1).iso8601(9)), @snapshot.merge("wallet_address" => "other") ].each do |snapshot|
      built = adapter(external_accounts: [ external(snapshot: snapshot, prices: nil) ])
      assert_raises(Provider::AccountData::IncompletePage) { built.fetch_balance(account: @account) }
    end
  end

  test "quotes are bound to asset snapshot currency and explicit symbol" do
    [ { "snapshot_sha256" => "wrong" }, { "currency" => "EUR" }, { "external_id" => "other" }, { "ticker" => "CRYPTO:ETH" } ].each do |change|
      built = adapter(external_accounts: [ external(prices: prices.merge(change)) ])
      assert_raises(Provider::AccountData::InvalidResponse) { built.fetch_balance(account: @account) }
    end
  end

  test "dated FX is captured and cannot silently relabel a native quote" do
    converted = quote("45000", original_price: "50000", original_currency: "USD", fx_rate: "0.9", fx_date: "2026-05-08")
    data = external(prices: prices(currency: "EUR", current: converted, historical: {})).merge(currency: "EUR")
    built = adapter(external_accounts: [ data ])
    assert_equal BigDecimal("90000"), built.fetch_balance(account: built.list_accounts.records.sole).records.sole[:balance]
    data[:sensitive_details]["onchain_prices"]["current"]["price"] = "50000"
    assert_raises(Provider::AccountData::InvalidResponse) { adapter(external_accounts: [ data ]).fetch_balance(account: @account) }
  end

  test "historical prices must be exact day while current quote may precede observation" do
    assert @adapter.fetch_balance(account: @account).complete?
    wrong_day = prices(historical: { "2026-05-08" => quote("40000", date: "2026-05-07") })
    built = adapter(external_accounts: [ external(prices: wrong_day) ])
    assert_raises(Provider::AccountData::InvalidResponse) { built.fetch_activities(account: @account) }
  end

  test "movement paging is bounded and cursors require the original snapshot and account" do
    rows = 101.times.map { |index| movement("tx-#{index.to_s.rjust(3, '0')}", "0.01") }
    snapshot = archive(movements: rows)
    data = external(snapshot: snapshot, prices: prices(snapshot: snapshot))
    built = adapter(external_accounts: [ data ])
    first = built.fetch_activities(account: @account)
    assert_not first.complete?
    assert_equal 100, first.records.size
    second = adapter(external_accounts: [ data ]).fetch_activities(account: @account, cursor: first.progress_cursor)
    assert second.complete?
    assert_equal "onchain_legacy-source-uuid_tx-100", second.records.sole[:external_id]
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_activities(account: @account, cursor: first.progress_cursor) }
  end

  test "history truncation survives all pages without dropping healthy observations" do
    rows = 101.times.map { |index| movement("tx-#{index.to_s.rjust(3, '0')}", "0.01") }
    snapshot = archive(movements: rows, history_truncated: true)
    built = adapter(external_accounts: [ external(snapshot: snapshot, prices: prices(snapshot: snapshot)) ])
    first = built.fetch_activities(account: @account)
    assert first.progress_cursor
    second = built.fetch_activities(account: @account, cursor: first.progress_cursor)
    assert_not second.complete?
    assert_equal 1, second.records.size
    assert_equal "history_truncated", second.warnings.sole["code"]
  end

  test "duplicate movement identities and future dates fail instead of merging different events" do
    [ [ @movements.first, @movements.first ], [ movement("future", "1", date: Date.new(2027, 1, 1)) ] ].each do |movements|
      snapshot = archive(movements: movements)
      built = adapter(external_accounts: [ external(snapshot: snapshot, prices: nil) ])
      assert_raises(Provider::AccountData::InvalidResponse) { built.fetch_activities(account: @account) }
    end
  end

  test "ERC20 contract case is canonical while SPL mint case remains identity" do
    evm = @descriptor.merge("chain" => "ethereum", "asset_kind" => "erc20", "wallet_address" => "0x#{'a' * 40}",
      "contract_address" => "0xabc", "symbol" => "USDC.e")
    assert_equal evm, Provider::AccountData::OnchainWallet::SourceDescriptor.validate!(evm)
    assert_raises(ArgumentError) { Provider::AccountData::OnchainWallet::SourceDescriptor.validate!(evm.merge("contract_address" => "0xAbC")) }
    spl = evm.merge("chain" => "solana", "asset_kind" => "spl", "contract_address" => "AbC")
    assert_equal "AbC", Provider::AccountData::OnchainWallet::SourceDescriptor.validate!(spl)["contract_address"]
    assert_not_equal Provider::AccountData::OnchainWallet::SourceDescriptor.external_id(spl), Provider::AccountData::OnchainWallet::SourceDescriptor.external_id(spl.merge("contract_address" => "abc"))
  end

  test "snapshots are immutable exact and stable across JSON object key order" do
    klass = Provider::AccountData::OnchainWallet::SnapshotArchive
    first = klass.new(@snapshot)
    reordered = @snapshot.to_a.reverse.to_h
    assert_equal first.fingerprint, klass.new(reordered).fingerprint
    assert_raises(FrozenError) { first.assets.first["quantity"] = "999" }
    assert_not_includes first.inspect, @descriptor["wallet_address"]
    bad = @snapshot.deep_dup
    bad["assets"].first["quantity"] = Float::INFINITY
    assert_raises(Provider::AccountData::InvalidResponse) { klass.new(bad) }
  end

  private
    def adapter(**options)
      Provider::AccountData::OnchainWallet.new(external_accounts: [ @external ], observed_at: @observed_at, timezone: "UTC", locale: "en", **options)
    end

    def movement(id, amount, date: Date.new(2026, 5, 8))
      Onchain::Movement.new(external_id: id, symbol: "BTC", contract: nil, amount: BigDecimal(amount), timestamp: date)
    end

    def archive(assets: [ @asset ], movements: @movements, **options)
      Provider::AccountData::OnchainWallet::SnapshotArchive.capture(
        snapshot: Onchain::Snapshot.new(assets: assets, movements: movements, **options), chain: @descriptor.fetch("chain"),
        address: @descriptor.fetch("wallet_address"), observed_at: @observed_at, evidence: { "request" => "captured" })
    end

    def external(snapshot: @snapshot, prices: self.prices)
      { id: "new-external-uuid", external_id: @external_id, name: "Bitcoin", currency: "USD", metadata: {},
        sensitive_details: { "source_descriptor" => @descriptor.deep_dup, "onchain_snapshot" => snapshot, "onchain_prices" => prices } }
    end

    def prices(snapshot: @snapshot, current: quote("50000"), historical: { "2026-05-08" => quote("40000") }, currency: "USD")
      { "version" => 1, "observed_at" => @observed_at.iso8601(9), "snapshot_sha256" => Provider::AccountData::OnchainWallet::SnapshotArchive.new(snapshot).fingerprint,
        "external_id" => @external_id, "ticker" => "CRYPTO:BTC", "currency" => currency, "current" => current, "historical" => historical }
    end

    def quote(price, date: "2026-05-08", original_price: price, original_currency: "USD", fx_rate: nil, fx_date: nil)
      { "price" => price, "date" => date, "original_price" => original_price, "original_currency" => original_currency, "fx_rate" => fx_rate, "fx_date" => fx_date }
    end
end

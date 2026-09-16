require "test_helper"
require_relative "../../../../support/provider_ingestion_test_helper"
require_relative "../../../../support/onchain_capture_test_helper"

class Provider::AccountData::OnchainWallet::CaptureSyncTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  include OnchainCaptureTestHelper
  self.use_transactional_tests = false

  setup do
    travel_to Time.utc(2026, 9, 15, 12)
    @family = families(:dylan_family)
    @family_values = @family.reload.attributes.slice("timezone", "latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
    @family.update_columns(timezone: "UTC")
    DebugLogEntry.stubs(:capture)
    @configuration = wallet_configuration
    Wallet::Configuration.stubs(:build).returns(@configuration)
    Provider::AccountData::Registry.stubs(:fetch).with("onchain_wallet").returns(Wallet)
    Wallet::Client.any_instance.stubs(:sleep)
  end

  teardown do
    Family.where(id: @family.id).update_all(@family_values)
    travel_back
  end

  test "production factory and Syncer capture physical reads outside locks before complete selected inventory" do
    with_wallet do |connection, external, sync|
      expect_bitcoin_summary
      expect_bitcoin_history
      assert_no_difference [ "Entry.count", "Holding.count", "Balance.count" ] do
        run_wallet(connection, sync)
      end
      batches = connection.ingestion_batches.order(:sequence).to_a
      assert_equal 4, batches.size # summary, history, disabled price decision, inventory
      assert batches.all?(&:applied?)
      pages = batches.map { |batch| Ingestion::Codec.load(batch.payload) }
      assert pages.first(3).all? { |page| page.records.empty? && page.progress_cursor && !page.complete? }
      assert pages.last.complete?
      assert_equal external.external_id, pages.last.records.sole[:external_id]
      assert_equal sync.created_at, connection.provider_sync_checkpoints.find_by!(stream: "accounts").covered_through
      assert_empty connection.provider_sync_checkpoints.where(stream: "activities")
      assert_provider_column_encrypted(batches.first, :payload, BITCOIN_ADDRESS)
      assert_equal "onchain_#{@source[:external][:id]}", external.reload.sensitive_details.dig("source_descriptor", "ingestion_namespace")
      refute external.sensitive_details.key?("onchain_snapshot")
      refute Wallet.native_ready?
    end
  end

  test "captured but unapplied response is replayed by a newly constructed adapter without another summary read" do
    with_wallet do |connection, _external, sync|
      expect_bitcoin_summary
      Provider::AccountData::RequestGrant.stubs(:verify_capture!).raises(IOError, "interruption")
      assert_raises(Provider::AccountData::Error) { run_wallet(connection, sync) }
      captured = connection.ingestion_batches.sole
      assert_equal "captured", captured.status
      original_payload = captured.payload
      Provider::AccountData::RequestGrant.unstub(:verify_capture!)
      travel 2.days
      expect_bitcoin_history
      run_wallet(connection.reload, Sync.find(sync.id))
      assert captured.reload.applied?
      assert_equal original_payload, captured.payload
      assert_equal 4, connection.ingestion_batches.count
      context = Wallet::CaptureArchive.build(connection: connection.reload, sync: sync.reload, observed_at: sync.created_at)
      assert_equal sync.created_at.getutc.iso8601(9), context.dig("scope", "observed_at")
      assert_equal [ "2026-09-15", "2026-09-17", "2026-09-17" ], context["fragments"].map { |fragment| Time.iso8601(fragment["fetched_at"]).utc.to_date.iso8601 }
    end
  end

  test "a completed resumed inventory reconstructs its original wallet and makes no network requests" do
    with_wallet do |connection, external, sync|
      expect_bitcoin_summary
      expect_bitcoin_history
      run_wallet(connection, sync)
      original_ids = connection.ingestion_batches.order(:sequence).pluck(:id)
      travel 1.day
      assert_no_difference "IngestionBatch.count" do
        run_wallet(connection.reload, Sync.find(sync.id))
      end
      assert_equal original_ids, connection.ingestion_batches.order(:sequence).pluck(:id)
      adapter = Provider::AccountData::Registry.build(connection.reload, sync: sync.reload, observed_at: sync.created_at)
      balance = adapter.fetch_balance(account: Ingestion::Record.account(external_id: external.external_id, name: "Selected", currency: "USD"))
      assert_equal "2.0", balance.records.sole[:metadata][:asset][:quantity]
      refute balance.complete? # the deliberately disabled quote is not zero
    end
  end

  test "repeated attempt sequence numbers may repeat identical fragments but cannot select a newer conflicting response" do
    with_wallet do |connection, _external, sync|
      expect_bitcoin_summary
      Provider::AccountData::RequestGrant.stubs(:verify_capture!).raises(IOError)
      assert_raises(Provider::AccountData::Error) { run_wallet(connection, sync) }
      Provider::AccountData::RequestGrant.unstub(:verify_capture!)
      original = connection.ingestion_batches.sole
      duplicate = create_provider_batch(connection, sync: sync, sequence: original.sequence, complete: original.complete?, mode: original.mode,
        payload: original.payload, source_binding: original.source_binding)
      context = Wallet::CaptureArchive.build(connection: connection.reload, sync: sync.reload, observed_at: sync.created_at)
      assert_equal 1, context.fetch("fragments").size
      duplicate.delete
      payload = original.payload.deep_dup
      page = Ingestion::Codec.load(payload)
      evidence = page.evidence.deep_dup
      fragment = evidence.fetch("onchain_capture").fetch("fragment")
      fragment["response"]["chain_stats"]["funded_txo_sum"] += 1
      evidence["onchain_capture"]["prefix_sha256"] = Wallet::CaptureArchive.digest(fragment)
      changed = Provider::AccountData::Page.new(records: [], complete: false, mode: "snapshot", next_cursor: page.next_cursor,
        progress_cursor: page.progress_cursor, evidence: evidence, coverage: page.coverage)
      create_provider_batch(connection, sync: sync, sequence: original.sequence, complete: false, payload: Ingestion::Codec.dump(changed), source_binding: original.source_binding)
      assert_raises(Provider::AccountData::InvalidResponse) { Wallet::CaptureArchive.build(connection: connection, sync: sync, observed_at: sync.created_at) }
    end
  end

  test "factory pins explorer configuration and source descriptor before HTTP and before publication" do
    [ :before_request, :during_request ].each do |stage|
      with_wallet do |connection, external, sync|
        if stage == :before_request
          adapter = Provider::AccountData::Registry.build(connection, sync: sync, observed_at: sync.created_at)
          @configuration["bitcoin_url"] = "https://changed.example.test"
          assert_raises(Provider::AccountData::StaleWriter) do
            adapter.request_grant.capture_request(scope_sync: sync) { flunk "Stale factory cannot issue HTTP" }
          end
        else
          Provider::MempoolSpace.expects(:get).once.with do |_url, **options|
            assert_equal false, options[:follow_redirects]
            assert_equal 0, ApplicationRecord.connection.open_transactions
            details = external.reload.sensitive_details.deep_dup
            details["source_descriptor"]["ingestion_namespace"] = "onchain_changed"
            external.update!(sensitive_details: details)
            true
          end.returns(stub(code: 200, body: JSON.generate(bitcoin_summary)))
          assert_raises(Provider::AccountData::StaleWriter) { run_wallet(connection, sync) }
          assert_equal [ "captured" ], connection.ingestion_batches.pluck(:status)
          assert_empty connection.provider_sync_checkpoints
        end
      end
      @configuration["bitcoin_url"] = Provider::MempoolSpace.base_url
    end
  end

  test "new Sync never substitutes prior captures or legacy raw snapshot with current observation time" do
    with_wallet do |connection, external, sync|
      expect_bitcoin_summary
      expect_bitcoin_history
      run_wallet(connection, sync)
      external.update!(sensitive_details: external.sensitive_details.merge("onchain_snapshot" => { "obsolete" => true }))
      travel 1.day
      new_sync = connection.syncs.create!(status: "syncing")
      assert_empty Wallet::CaptureArchive.build(connection: connection, sync: new_sync, observed_at: new_sync.created_at).fetch("fragments")
      expect_bitcoin_summary(quantity: "300000000")
      expect_bitcoin_history
      run_wallet(connection.reload, new_sync)
      adapter = Provider::AccountData::Registry.build(connection.reload, sync: new_sync, observed_at: new_sync.created_at)
      record = Ingestion::Record.account(external_id: external.external_id, name: "Selected", currency: "USD")
      assert_equal "3.0", adapter.fetch_balance(account: record).records.sole[:metadata][:asset][:quantity]
    end
  end

  test "a new Sync discards an older failed inventory continuation and captures a fresh wallet" do
    with_wallet do |connection, _external, sync|
      expect_bitcoin_summary
      Provider::MempoolSpace.expects(:get).once.with { |url, **_options| url.end_with?("/txs") }.raises(Net::ReadTimeout)
      assert_raises(Provider::AccountData::Error) { run_wallet(connection, sync) }
      checkpoint = connection.provider_sync_checkpoints.find_by!(stream: "accounts")
      previous = checkpoint.state.fetch("progress").fetch("cursor")
      assert previous.present?
      sync.update!(status: "failed")
      travel 1.day
      current = connection.syncs.create!(status: "syncing")
      expect_bitcoin_summary(quantity: "300000000")
      expect_bitcoin_history
      run_wallet(connection.reload, current)
      assert_equal current.id, checkpoint.reload.ingestion_batch.sync_id
      assert_nil checkpoint.state["progress"]
      assert_equal 1, connection.ingestion_batches.where(sync: sync).count
      assert_equal 4, connection.ingestion_batches.where(sync: current).count
    end
  end

  test "collector rejects original Sync clock mismatch and a broken capture prefix" do
    with_wallet do |connection, _external, sync|
      expect_bitcoin_summary
      Provider::AccountData::RequestGrant.stubs(:verify_capture!).raises(IOError)
      assert_raises(Provider::AccountData::Error) { run_wallet(connection, sync) }
      Provider::AccountData::RequestGrant.unstub(:verify_capture!)
      assert_raises(Provider::AccountData::InvalidResponse) do
        Wallet::CaptureArchive.build(connection: connection, sync: sync, observed_at: sync.created_at + 1.second)
      end
      batch = connection.ingestion_batches.sole
      page = Ingestion::Codec.load(batch.payload)
      capture = Wallet::CaptureArchive.build(connection: connection, sync: sync, observed_at: sync.created_at)
      capture = capture.deep_dup
      capture["fragments"].first["previous_sha256"] = "0" * 64
      assert_raises(Provider::AccountData::InvalidResponse) do
        Wallet.build(credentials: {}, settings: {}, context: { external_accounts: Provider::AccountData::RuntimeContext.new(connection).external_accounts, timezone: "UTC", family_locale: "en",
          observed_at: sync.created_at, connection_details: {}, onchain_configuration: @configuration,
          onchain_fx_credentials: Wallet::FxConfiguration.credentials, onchain_capture: capture })
      end
      assert page.evidence.key?(Provider::AccountData::RequestGrant::EVIDENCE_KEY)
    end
  end

  test "cached FX chooses actual nearest day and never invokes a provider for an absent pair" do
    rate = ExchangeRate.create!(from_currency: "USD", to_currency: "CHF", date: Date.new(2026, 9, 13), rate: BigDecimal("0.89"))
    ExchangeRate.expects(:provider).never
    resolver = Wallet::CachedExchangeRateResolver.new
    value = resolver.call(from: "USD", to: "CHF", date: Date.new(2026, 9, 15))
    assert_equal BigDecimal("0.89"), value[:rate]
    assert_equal "2026-09-13", value[:date]
    assert_equal "cached_exchange_rate", value[:source]
    assert_nil resolver.call(from: "USD", to: "CHF", date: Date.new(2026, 9, 20))
  ensure
    ExchangeRate.where(id: rate&.id).delete_all
  end

  test "production wallet capture feeds activity pagination with original namespace and fixed exact price dates" do
    with_wallet do |connection, external, sync|
      @configuration["price_enabled"] = true
      expect_bitcoin_summary
      history = 101.times.map do |index|
        { "txid" => index.to_s(16).rjust(64, "0"), "vin" => [], "vout" => [ { "scriptpubkey_address" => BITCOIN_ADDRESS, "value" => 1 } ],
          "status" => { "block_time" => Time.utc(2026, 9, 14, 12).to_i } }
      end
      Provider::MempoolSpace.expects(:get).once.with { |url, **_options| url.end_with?("/txs") }.returns(stub(code: 200, body: JSON.generate(history)))
      Provider::MempoolSpace.expects(:get).once.with { |url, **_options| url.end_with?("/txs/chain/#{history.last['txid']}") }.returns(stub(code: 200, body: "[]"))
      %w[2026-09-14 2026-09-15].each do |date|
        rows = daily_quote(date: date).fetch("rows")
        Wallet::Client::PublicHttp.expects(:get).once.with do |_url, **options|
          assert_equal 0, ApplicationRecord.connection.open_transactions
          options.dig(:query, :startTime) == rows.first.first && options.dig(:query, :limit) == 1
        end.returns(stub(code: 200, body: JSON.generate(rows)))
      end
      run_wallet(connection, sync)
      build = -> { Provider::AccountData::Registry.build(connection.reload, sync: sync.reload, observed_at: sync.created_at) }
      record = Ingestion::Record.account(external_id: external.external_id, name: "Selected", currency: "USD")
      first = build.call.fetch_activities(account: record)
      assert_equal 100, first.records.size
      refute first.complete?
      assert first.progress_cursor
      travel 1.day
      last = build.call.fetch_activities(account: record, cursor: first.progress_cursor)
      assert last.complete?
      assert_equal 1, last.records.size
      assert_equal "#{@source[:descriptor]['ingestion_namespace']}_#{history.last['txid']}", last.records.sole[:external_id]
      assert_equal Date.new(2026, 9, 14), last.records.sole[:date]
      assert_equal BigDecimal("50000"), last.records.sole[:price]
      assert_equal :sync, build.call.progress_cursor_scope(stream: "activities")
      current = connection.syncs.create!(status: "syncing")
      expect_bitcoin_summary(quantity: "300000000")
      Provider::MempoolSpace.expects(:get).once.with { |url, **_options| url.end_with?("/txs") }.returns(stub(code: 200, body: JSON.generate(history)))
      Provider::MempoolSpace.expects(:get).once.with { |url, **_options| url.include?("/txs/chain/") }.returns(stub(code: 200, body: "[]"))
      %w[2026-09-14 2026-09-16].each do |date|
        rows = daily_quote(date: date).fetch("rows")
        Wallet::Client::PublicHttp.expects(:get).once.with { |_url, **options| options.dig(:query, :startTime) == rows.first.first }
          .returns(stub(code: 200, body: JSON.generate(rows)))
      end
      run_wallet(connection.reload, current)
      fresh = Provider::AccountData::Registry.build(connection.reload, sync: current, observed_at: current.created_at)
      assert_raises(Provider::AccountData::InvalidResponse) { fresh.fetch_activities(account: record, cursor: first.progress_cursor) }
    end
  end

  test "aggregate stored and decoded archive bounds reject before factory materialization" do
    with_wallet do |connection, _external, sync|
      expect_bitcoin_summary
      Provider::AccountData::RequestGrant.stubs(:verify_capture!).raises(IOError)
      assert_raises(Provider::AccountData::Error) { run_wallet(connection, sync) }
      Provider::AccountData::RequestGrant.unstub(:verify_capture!)
      archive = -> { Wallet::CaptureArchive.build(connection: connection, sync: sync, observed_at: sync.created_at) }
      with_capture_limit(:MAX_STORED_BYTES, 1) do
        Ingestion::Codec.expects(:load).never
        assert_raises(Provider::AccountData::IncompletePage, &archive)
      end
      with_capture_limit(:MAX_BYTES, 1) do
        assert_raises(Provider::AccountData::IncompletePage, &archive)
      end
    end
  end

  test "a captured Frankfurter response fills missing cached FX and replays without another request or rate-table write" do
    with_wallet do |connection, external, sync|
      external.update!(currency: "EUR")
      configure_frankfurter
      @configuration["price_enabled"] = true
      expect_bitcoin_summary
      expect_bitcoin_history
      price_rows = daily_quote(date: "2026-09-15").fetch("rows")
      Wallet::Client::PublicHttp.expects(:get).once.returns(stub(code: 200, body: JSON.generate(price_rows)))
      Wallet::CachedExchangeRateResolver.any_instance.expects(:call).once.with(from: "USD", to: "EUR", date: Date.new(2026, 9, 15)).returns(nil)
      Wallet::FxReader::Http.expects(:get).once.with do |url, **options|
        assert_equal 0, ApplicationRecord.connection.open_transactions
        url == "https://fx.example.test/rate/USD/EUR" && options == { query: { date: "2026-09-15" }, follow_redirects: false }
      end.returns(stub(code: 200, body: '{"base":"USD","quote":"EUR","date":"2026-09-14","rate":0.9}'))
      assert_no_difference "ExchangeRate.count" { run_wallet(connection, sync) }
      assert_equal 6, connection.ingestion_batches.count
      fragment = Wallet::CaptureArchive.build(connection: connection, sync: sync, observed_at: sync.created_at).fetch("fragments")
        .find { |value| value.dig("operation", "action") == "fx_remote" }
      assert_equal "frankfurter", fragment.dig("response", "provider")
      assert_equal "2026-09-14", fragment.dig("response", "response", "date")
      travel 2.days
      run_wallet(connection.reload, sync.reload)
      adapter = Provider::AccountData::Registry.build(connection.reload, sync: sync, observed_at: sync.created_at)
      page = adapter.fetch_balance(account: Ingestion::Record.account(external_id: external.external_id, name: "Selected", currency: "EUR"))
      assert page.complete?
      assert_equal "EUR", page.records.sole[:currency]
      assert_equal BigDecimal("90000"), page.records.sole[:balance]
      assert_equal "2026-09-14", page.evidence.dig("prices", "current", "fx_date")
    end
  end

  test "same Sync retries throttled and unavailable FX after its immutable successful prefix" do
    with_wallet do |connection, external, sync|
      external.update!(currency: "EUR")
      configure_frankfurter
      @configuration["price_enabled"] = true
      expect_bitcoin_summary
      expect_bitcoin_history
      price_rows = daily_quote(date: "2026-09-15").fetch("rows")
      Wallet::Client::PublicHttp.expects(:get).once.returns(stub(code: 200, body: JSON.generate(price_rows)))
      Wallet::CachedExchangeRateResolver.any_instance.expects(:call).once.returns(nil)
      Wallet::FxReader::Http.expects(:get).times(3).with do |url, **options|
        assert_equal 0, ApplicationRecord.connection.open_transactions
        url == "https://fx.example.test/rate/USD/EUR" && options == { query: { date: "2026-09-15" }, follow_redirects: false }
      end.returns(stub(code: 429, body: "throttled"), stub(code: 503, body: "unavailable"),
        stub(code: 200, body: '{"base":"USD","quote":"EUR","date":"2026-09-14","rate":0.9}'))

      assert_raises(Provider::AccountData::Error) { run_wallet(connection, sync) }
      prefix = connection.ingestion_batches.order(:id).map { |batch| [ batch.id, batch.payload ] }
      assert_equal 4, prefix.size
      assert connection.ingestion_batches.all?(&:applied?)
      refute connection.provider_sync_checkpoints.find_by!(stream: "accounts").covered_through
      travel 1.day
      assert_raises(Provider::AccountData::Error) { run_wallet(connection.reload, Sync.find(sync.id)) }
      assert_equal prefix, connection.ingestion_batches.order(:id).map { |batch| [ batch.id, batch.payload ] }

      run_wallet(connection.reload, Sync.find(sync.id))
      assert_equal 6, connection.ingestion_batches.count
      assert_equal prefix, connection.ingestion_batches.where(id: prefix.map(&:first)).order(:id).map { |batch| [ batch.id, batch.payload ] }
      capture = Wallet::CaptureArchive.build(connection: connection, sync: sync, observed_at: sync.created_at)
      remote = capture.fetch("fragments").select { |fragment| fragment.dig("operation", "action") == "fx_remote" }.sole
      assert_equal "response", remote.dig("response", "status")
      assert_equal "2026-09-16", Time.iso8601(remote.fetch("fetched_at")).utc.to_date.iso8601
      assert_equal "2026-09-14", remote.dig("response", "response", "date")
      assert_equal sync.created_at, connection.provider_sync_checkpoints.find_by!(stream: "accounts").covered_through
    end
  end

  test "existing dated cached FX remains the captured fallback without a remote request" do
    with_wallet do |connection, external, sync|
      external.update!(currency: "EUR")
      configure_frankfurter
      @configuration["price_enabled"] = true
      expect_bitcoin_summary
      expect_bitcoin_history
      price_rows = daily_quote(date: "2026-09-15").fetch("rows")
      Wallet::Client::PublicHttp.expects(:get).once.returns(stub(code: 200, body: JSON.generate(price_rows)))
      Wallet::CachedExchangeRateResolver.any_instance.expects(:call).once.returns(rate: BigDecimal("0.8"), date: "2026-09-13", source: "cached_exchange_rate", id: "retained-rate")
      Wallet::FxReader::Http.expects(:get).never
      run_wallet(connection, sync)
      fragments = Wallet::CaptureArchive.build(connection: connection, sync: sync, observed_at: sync.created_at).fetch("fragments")
      refute fragments.any? { |value| value.dig("operation", "action") == "fx_remote" }
      assert_equal "cached_exchange_rate", fragments.find { |value| value.dig("operation", "action") == "fx" }.dig("response", "source")
      adapter = Provider::AccountData::Registry.build(connection.reload, sync: sync, observed_at: sync.created_at)
      page = adapter.fetch_balance(account: Ingestion::Record.account(external_id: external.external_id, name: "Selected", currency: "EUR"))
      assert_equal BigDecimal("80000"), page.records.sole[:balance]
      assert_equal "2026-09-13", page.evidence.dig("prices", "current", "fx_date")
    end
  end

  test "captured unapplied MOEX history resumes at the next physical page with original dates after midnight" do
    with_wallet do |connection, external, sync|
      external.update!(currency: "RUB")
      configure_moex
      @configuration["price_enabled"] = true
      expect_bitcoin_summary
      expect_bitcoin_history
      price_rows = daily_quote(date: "2026-09-15").fetch("rows")
      Wallet::Client::PublicHttp.expects(:get).once.returns(stub(code: 200, body: JSON.generate(price_rows)))
      Wallet::CachedExchangeRateResolver.any_instance.expects(:call).once.returns(nil)
      first_history = { "columns" => %w[BOARDID SECID TRADEDATE CLOSE WAPRICE],
        "data" => Array.new(100) { [ "CETS", "USD000UTSTOM", "2026-09-05", "90", nil ] } }
      Wallet::MoexFxReader::Http.expects(:get).once.with do |url, **options|
        assert_equal 0, ApplicationRecord.connection.open_transactions
        Provider::AccountData::RequestGrant.stubs(:verify_capture!).raises(IOError, "interrupted after physical page capture")
        url.end_with?("/CETS/securities/USD000UTSTOM.json") && options.dig(:query, "start") == 0
      end.returns(stub(code: 200, body: JSON.generate("history" => first_history)))
      assert_raises(Provider::AccountData::Error) { run_wallet(connection, sync) }
      Provider::AccountData::RequestGrant.unstub(:verify_capture!)
      captured = connection.ingestion_batches.where(status: "captured").sole
      original_payload = captured.payload
      assert_equal 5, connection.ingestion_batches.count
      assert_equal "fx_moex_history", Ingestion::Codec.load(original_payload).evidence.dig("onchain_capture", "fragment", "operation", "action")
      refute connection.provider_sync_checkpoints.find_by!(stream: "accounts").covered_through

      travel 2.days
      last_history = first_history.merge("data" => [ [ "CETS", "USD000UTSTOM", "2026-09-14", "91", nil ] ])
      Wallet::MoexFxReader::Http.expects(:get).once.with do |_url, **options|
        assert_equal 0, ApplicationRecord.connection.open_transactions
        options.fetch(:query).slice("from", "till", "start") == { "from" => "2026-09-05", "till" => "2026-09-15", "start" => 100 }
      end.returns(stub(code: 200, body: JSON.generate("history" => last_history)))
      assert_no_difference "ExchangeRate.count" { run_wallet(connection.reload, Sync.find(sync.id)) }
      assert captured.reload.applied?
      assert_equal original_payload, captured.payload
      assert_equal 7, connection.ingestion_batches.count
      fragments = Wallet::CaptureArchive.build(connection: connection, sync: sync, observed_at: sync.created_at).fetch("fragments")
        .select { |fragment| fragment.dig("operation", "action") == "fx_moex_history" }
      assert_equal [ 0, 100 ], fragments.map { |fragment| fragment.dig("operation", "arguments", "start") }
      assert_equal [ "2026-09-15", "2026-09-17" ], fragments.map { |fragment| Time.iso8601(fragment.fetch("fetched_at")).utc.to_date.iso8601 }
      adapter = Provider::AccountData::Registry.build(connection.reload, sync: sync, observed_at: sync.created_at)
      page = adapter.fetch_balance(account: Ingestion::Record.account(external_id: external.external_id, name: "Selected", currency: "RUB"))
      assert page.complete?
      assert_equal BigDecimal("9100000"), page.records.sole[:balance]
      assert_equal "2026-09-14", page.evidence.dig("prices", "current", "fx_date")
      assert_no_difference "IngestionBatch.count" { run_wallet(connection.reload, Sync.find(sync.id)) }
    ensure
      Provider::AccountData::RequestGrant.unstub(:verify_capture!)
    end
  end

  test "empty MOEX dated history leaves valuation unavailable without a current-market quote or zero balance" do
    with_wallet do |connection, external, sync|
      external.update!(currency: "RUB")
      configure_moex
      @configuration["price_enabled"] = true
      expect_bitcoin_summary
      expect_bitcoin_history
      rows = daily_quote(date: "2026-09-15").fetch("rows")
      Wallet::Client::PublicHttp.expects(:get).once.returns(stub(code: 200, body: JSON.generate(rows)))
      Wallet::CachedExchangeRateResolver.any_instance.expects(:call).once.returns(nil)
      Wallet::MoexFxReader::Http.expects(:get).once.with { |url, **_options| url.include?("/history/") }
        .returns(stub(code: 200, body: JSON.generate("history" => { "columns" => %w[BOARDID SECID TRADEDATE CLOSE WAPRICE], "data" => [] })))
      assert_no_difference [ "Balance.count", "Holding.count" ] { run_wallet(connection, sync) }
      adapter = Provider::AccountData::Registry.build(connection.reload, sync: sync, observed_at: sync.created_at)
      page = adapter.fetch_balance(account: Ingestion::Record.account(external_id: external.external_id, name: "Selected", currency: "RUB"))
      refute page.complete?
      assert_nil page.records.sole[:balance]
      assert_equal "asset_valuation_unavailable", page.warnings.sole["code"]
    end
  end

  private
    def configure_moex
      credentials = { "provider" => "moex_public" }
      Wallet::FxConfiguration.stubs(:credentials).returns(credentials)
      @configuration["fx"] = { "version" => 1, "provider" => "moex_public", "endpoint" => "https://moex.example.test/iss", "min_interval_seconds" => "0.4",
        "credential_fingerprint" => Wallet::FxConfiguration.fingerprint(credentials), "history_policy" => Wallet::MoexFxReader.policy }
    end

    def configure_frankfurter
      credentials = { "provider" => "frankfurter" }
      Wallet::FxConfiguration.stubs(:credentials).returns(credentials)
      @configuration["fx"] = { "version" => 1, "provider" => "frankfurter", "endpoint" => "https://fx.example.test", "min_interval_seconds" => "0.4",
        "credential_fingerprint" => Wallet::FxConfiguration.fingerprint(credentials) }
    end

    def with_wallet
      with_provider_encryption do
        connection = create_provider_connection(provider_key: "onchain_wallet", credentials: {})
        @source = wallet_source
        external = create_external_account(connection, external_id: @source[:external][:external_id], name: @source[:external][:name],
          account_type: "Crypto", sensitive_details: @source[:external][:sensitive_details])
        sync = connection.syncs.create!(status: "syncing")
        yield connection, external, sync
      ensure
        if connection
          ProviderConnection.where(id: connection.id).update_all(lease_sync_id: nil, lease_owner: nil, lease_expires_at: nil)
          ProviderSyncCheckpoint.where(provider_connection_id: connection.id).delete_all
          IngestionBatch.where(provider_connection_id: connection.id).delete_all
          ExternalAccount.where(provider_connection_id: connection.id).delete_all
          Sync.where(syncable_type: "ProviderConnection", syncable_id: connection.id).delete_all
          ProviderConnection.where(id: connection.id).delete_all
        end
      end
    end

    def expect_bitcoin_summary(quantity: "200000000")
      Provider::MempoolSpace.expects(:get).once.with do |url, **options|
        assert_equal 0, ApplicationRecord.connection.open_transactions
        url == "#{@configuration['bitcoin_url'].delete_suffix('/')}/address/#{BITCOIN_ADDRESS}" && options[:follow_redirects] == false
      end.returns(stub(code: 200, body: JSON.generate(bitcoin_summary(quantity: quantity))))
    end

    def expect_bitcoin_history
      Provider::MempoolSpace.expects(:get).once.with do |url, **options|
        assert_equal 0, ApplicationRecord.connection.open_transactions
        url == "#{@configuration['bitcoin_url'].delete_suffix('/')}/address/#{BITCOIN_ADDRESS}/txs" && options[:follow_redirects] == false
      end.returns(stub(code: 200, body: "[]"))
    end

    def run_wallet(connection, sync)
      Provider::AccountData::Syncer.new(connection).perform_sync(sync)
    end

    def with_capture_limit(name, value)
      previous = Wallet::CaptureArchive.const_get(name)
      Wallet::CaptureArchive.send(:remove_const, name)
      Wallet::CaptureArchive.const_set(name, value)
      yield
    ensure
      Wallet::CaptureArchive.send(:remove_const, name)
      Wallet::CaptureArchive.const_set(name, previous)
    end
end

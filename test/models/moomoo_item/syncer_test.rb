require "test_helper"

class MoomooItem::SyncerTest < ActiveSupport::TestCase
  # Answers like Provider::Moomoo with one healthy shared account.
  class FakeProvider
    METHODS = %i[get_accounts get_funds get_positions get_today_fills get_fills_history get_orders_history get_cash_logs].freeze

    attr_reader :calls

    def initialize
      @calls = []
      @handlers = {}
    end

    def on(method, &handler)
      @handlers[method] = handler
    end

    def calls_to(method)
      calls.filter_map { |name, args| args if name == method }
    end

    METHODS.each do |method|
      define_method(method) do |_token, **args|
        @calls << [ method, args ]
        @handlers[method] ? @handlers[method].call(args) : default_response(method)
      end
    end

    private

      def default_response(method)
        case method
        when :get_accounts
          [ { "account_id" => 1234567890123456, "security_firm" => "FUTUSG", "enable_market" => [ 6, 2, 1 ], "acc_type" => "margin", "account_card_number" => "1001234567893456" } ]
        when :get_positions then []
        when :get_funds then { "currency" => "SGD", "total_assets" => "12345.67", "cash" => "1" }
        else { records: [], truncated: false }
        end
      end
  end

  setup do
    travel_to Time.zone.parse("2026-10-24 12:00:00")

    @item = moomoo_items(:connected_item)
    @item.update!(access_token_expires_at: 1.day.from_now)
    @moomoo_account = moomoo_accounts(:main_account)
    @account = @item.family.accounts.create!(name: "moomoo SG", balance: 0, cash_balance: 0, currency: "SGD", accountable: Investment.new)
    @moomoo_account.ensure_account_provider!(@account)

    @provider = FakeProvider.new
    MoomooItem.any_instance.stubs(:moomoo_provider).returns(@provider)
    @sync = @item.syncs.create!
  end

  test "a connection without tokens is not synced and reports an auth error" do
    @item.update!(access_token: nil, refresh_token: nil)
    MoomooItem::Importer.any_instance.expects(:import).never

    error = assert_raises(Provider::Moomoo::MoomooError) { perform_sync }

    assert_equal :not_connected, error.error_type
    assert_equal "auth_error", @sync.reload.sync_stats["errors"].first["category"]
  end

  test "a refresh token moomoo refused flags the connection and reports an auth error" do
    MoomooItem.any_instance.unstub(:moomoo_provider)
    @item.update!(access_token_expires_at: 1.minute.ago)
    Provider::Moomoo.any_instance.stubs(:refresh_access_token).raises(Provider::Moomoo::MoomooError.new("expired", :invalid_grant, status: 400))

    assert_raises(Provider::Moomoo::MoomooError) { perform_sync }

    assert @item.reload.requires_update?
    assert_equal "invalid_grant", @item.reauth_reason
    assert_equal "auth_error", @sync.reload.sync_stats["errors"].first["category"]
  end

  test "an unexpected failure reports a sync error" do
    MoomooItem::Importer.any_instance.stubs(:import).raises(StandardError, "boom")

    assert_raises(StandardError) { perform_sync }

    assert_equal({ "message" => "boom", "category" => "sync_error" }, @sync.reload.sync_stats["errors"].first)
  end

  test "an unlinked account asks for setup and nothing is processed" do
    @moomoo_account.account_provider.destroy!
    MoomooItem.any_instance.expects(:process_accounts).never
    MoomooItem.any_instance.expects(:schedule_account_syncs).never

    perform_sync

    assert @item.reload.pending_account_setup?
  end

  test "a linked account is processed and its sync is scheduled under this one" do
    @item.update!(pending_account_setup: true)

    assert_difference -> { @account.syncs.count }, 1 do
      perform_sync
    end

    assert_not @item.reload.pending_account_setup?
    assert_equal BigDecimal("12345.67"), @account.reload.balance
    assert_equal @sync, @account.syncs.order(:created_at).last.parent
  end

  test "a disabled linked account is neither processed nor synced" do
    @account.disable!
    MoomooAccount::Processor.expects(:new).never

    assert_no_difference -> { @account.syncs.count } do
      perform_sync
    end
  end

  test "a clean sync reports no errors" do
    perform_sync

    stats = @sync.reload.sync_stats
    assert_equal 0, stats["total_errors"]
    assert_nil stats["rate_limited"]
  end

  test "an account that fails to process is reported in sync health" do
    MoomooAccount::Processor.any_instance.stubs(:process).raises(StandardError, "processor boom")

    perform_sync

    stats = @sync.reload.sync_stats
    assert_equal 1, stats["total_errors"]
    assert_equal({ "message" => "processor boom", "category" => "sync_error" }, stats["errors"].first)
  end

  test "an account sync that can't be scheduled is reported in sync health" do
    Account.any_instance.stubs(:sync_later).raises(StandardError, "enqueue failed")

    perform_sync

    stats = @sync.reload.sync_stats
    assert_equal 1, stats["total_errors"]
    assert_equal "enqueue failed", stats["errors"].first["message"]
  end

  test "a market whose trade history fails is reported as a partial failure" do
    @provider.on(:get_fills_history) do |args|
      raise Provider::Moomoo::MoomooError.new("moomoo GET /fills_history failed (200 / -1): market not open", :api_error, code: -1) if args[:trd_market] == "HK"

      { records: [], truncated: false }
    end

    perform_sync

    stats = @sync.reload.sync_stats
    assert_equal 1, stats["total_errors"]
    error = stats["errors"].first
    assert_equal "partial_fetch", error["category"]
    assert_equal "#{@moomoo_account.reload.name} · #{I18n.t('moomoo_items.sync.failures.recent_trade_history', market: 'HK')}", error["name"]
    assert_match "market not open", error["message"]
  end

  test "a rate limit that outlasts the retries is reported" do
    @provider.on(:get_today_fills) { raise Provider::Moomoo::MoomooError.new("slow down", :rate_limited, code: -12011) }

    perform_sync

    stats = @sync.reload.sync_stats
    assert stats["rate_limited"]
    assert_equal Time.current.iso8601, stats["rate_limited_at"]
    assert ProviderSyncSummary.new(stats: stats, provider_item: @item).rate_limited?
  end

  test "an account moomoo won't answer for keeps its last balance while the other one syncs" do
    broken = @item.moomoo_accounts.create!(
      moomoo_account_id: "777", name: "moomoo SG ••0777", currency: "SGD", account_kind: "securities",
      security_firm: "FUTUSG", enable_markets: [ 6 ], current_balance: 777
    )
    broken_account = @item.family.accounts.create!(name: "Broken", balance: 777, currency: "SGD", accountable: Investment.new)
    broken.ensure_account_provider!(broken_account)
    @provider.on(:get_accounts) do
      FakeProvider.new.get_accounts(nil) + [ { "account_id" => 777, "security_firm" => "FUTUSG", "enable_market" => [ 6 ], "account_card_number" => "1001234500000777" } ]
    end
    @provider.on(:get_funds) do |args|
      raise Provider::Moomoo::MoomooError.new("moomoo GET /funds failed (200 / -1): account restricted", :api_error, code: -1) if args[:acc_id] == "777"

      { "currency" => "SGD", "total_assets" => "12345.67", "cash" => "1" }
    end

    perform_sync

    assert_equal BigDecimal("12345.67"), @account.reload.balance
    assert_equal BigDecimal("777"), broken_account.reload.balance
    stats = @sync.reload.sync_stats
    assert_equal 1, stats["total_errors"]
    assert_equal [ "moomoo SG ••0777 · #{I18n.t('moomoo_items.sync.failures.balances_and_positions')}", "sync_error" ], stats["errors"].first.values_at("name", "category")
    assert_match "account restricted", stats["errors"].first["message"]
  end

  test "the holdings of an account the sync couldn't refresh are not counted as processed" do
    @moomoo_account.update!(raw_positions_payload: [ dbs(50) ])
    @provider.on(:get_funds) { { "currency" => "USD", "total_assets" => "1500", "cash" => "1500" } }

    perform_sync

    assert_equal 0, @sync.reload.sync_stats["holdings_processed"]
  end

  test "trades after the last usable snapshot wait for the next one, so the history before them is not counted twice" do
    Security::Resolver.stubs(:new).returns(stub(resolve: nil))
    buy = fill("b1", "BUY", Time.utc(2026, 10, 1, 2, 0))
    sell = fill("s1", "SELL", Time.utc(2026, 10, 25, 2, 0))
    funds = { "currency" => "SGD", "total_assets" => "2025", "cash" => "100" }
    positions = [ dbs(50) ]
    fills = [ buy ]
    @provider.on(:get_funds) { funds }
    @provider.on(:get_positions) { positions }
    @provider.on(:get_fills_history) { |args| { records: args[:trd_market] == "SG" ? fills : [], truncated: false } }

    sync_on("2026-10-24 12:00")

    # Funds moomoo reports in another currency are not used, so the
    # snapshot of 10-24 is kept although the position has since been sold.
    funds = { "currency" => "USD", "total_assets" => "1500", "cash" => "1500" }
    positions = []
    fills = [ buy, sell ]
    sync_on("2026-10-26 12:00")

    assert_nil @account.entries.find_by(external_id: "moomoo_fill_1234567890123456_s1")
    assert_equal BigDecimal("50"), dbs_qty_on(Date.new(2026, 10, 15))
    assert_equal BigDecimal("1600"), @account.balances.find_by!(date: Date.new(2026, 10, 15)).balance

    funds = { "currency" => "SGD", "total_assets" => "2025", "cash" => "2025" }
    sync_on("2026-10-27 12:00")

    assert @account.entries.find_by(external_id: "moomoo_fill_1234567890123456_s1")
    assert_equal BigDecimal("50"), dbs_qty_on(Date.new(2026, 10, 15))
    assert_equal BigDecimal("0"), dbs_qty_on(Date.current)
    assert_equal BigDecimal("1600"), @account.balances.find_by!(date: Date.new(2026, 10, 15)).balance
  end

  test "an unlinked cash account says it isn't imported, even with its currency's stocks account set up" do
    stocks = usd_row("stocks")
    usd_row("cash")
    stocks.ensure_account_provider!(@item.family.accounts.create!(name: "moomoo USD stocks", balance: 0, cash_balance: 0, currency: "USD", accountable: Investment.new))

    assert_equal [ "moomoo SG ••3456 (USD cash) is not imported until you set up its account." ], notices_without_import
  end

  test "an unlinked stocks account says it isn't imported, even with its currency's cash account set up" do
    usd_row("stocks")
    cash = usd_row("cash")
    cash.ensure_account_provider!(@item.family.accounts.create!(name: "moomoo USD cash", balance: 0, cash_balance: 0, currency: "USD", accountable: Investment.new))

    assert_equal [ "moomoo SG ••3456 (USD stocks) is not imported until you set up its account." ], notices_without_import
  end

  private

    def usd_row(role)
      @moomoo_account.currency_accounts.create!(
        moomoo_item: @item, moomoo_account_id: @moomoo_account.moomoo_account_id, currency: "USD", role: role,
        name: "moomoo SG ••3456 (USD #{role})", account_kind: "securities", security_firm: "FUTUSG", current_balance: 0, cash_balance: 0
      )
    end

    # The notices of a sync that keeps the rows as they are.
    def notices_without_import
      MoomooItem.any_instance.stubs(:import_latest_data).returns({})
      MoomooItem.any_instance.stubs(:process_accounts).returns([])
      MoomooItem.any_instance.stubs(:schedule_account_syncs).returns([])
      perform_sync
      Array(@sync.reload.sync_stats["data_quality_details"]).map { |detail| detail["message"] }
    end

    def perform_sync
      MoomooItem::Syncer.new(@item).perform_sync(@sync)
    end

    # Syncs at `time`, then materializes the account as its own sync would.
    def sync_on(time)
      travel_to Time.zone.parse(time)
      @item.update!(access_token_expires_at: 1.day.from_now)
      @sync = @item.syncs.create!
      perform_sync
      Balance::Materializer.new(Account.find(@account.id), strategy: :reverse).materialize_balances
    end

    def dbs_qty_on(date)
      @account.holdings.where(security: Security.find_by!(ticker: "D05", exchange_operating_mic: "XSES"), date: date).sum(:qty)
    end

    def dbs(qty)
      {
        "position_side" => "LONG", "code" => "SG.D05", "stock_name" => "DBS", "security_type" => "STOCK", "qty" => qty.to_s, "currency" => "SGD",
        "nominal_price" => "38.5", "cost_price_valid" => false, "market_val" => (BigDecimal(qty.to_s) * BigDecimal("38.5")).to_s("F")
      }
    end

    def fill(deal_id, side, at)
      micros = Provider::Moomoo.to_micros(at)
      {
        "deal_id" => deal_id, "order_id" => "o-#{deal_id}", "trd_side" => side, "code" => "SG.D05", "stock_name" => "DBS",
        "qty" => "50", "price" => side == "BUY" ? "30" : "38.5", "create_time" => micros, "updated_time" => micros, "status" => "OK"
      }
    end
end

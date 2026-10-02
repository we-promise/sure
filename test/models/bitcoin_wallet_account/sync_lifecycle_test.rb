require "test_helper"
require "support/bitcoin_wallet_test_helper"

class BitcoinWalletAccount::SyncLifecycleTest < ActiveSupport::TestCase
  include BitcoinWalletTestHelper

  setup do
    @account = accounts(:crypto)
    @account.entries.destroy_all
    @account.holdings.destroy_all
    @account.balances.destroy_all
    @account.update!(cash_balance: 100, balance: 100)
    @wallet = build_bitcoin_wallet(status: :preview, balance_sats: 20_000_000, last_synced_at: Time.current)
    manual_bitcoin_source(@wallet)
    @provider = FakeProvider.new
    @provider.fund(RECEIVE, 30_000_000)
    Provider::MempoolSpace.stubs(:new).returns(@provider)
  end

  test "the connection waits for both wallet read and account materialization" do
    @wallet.connect!
    parent = @wallet.onchain_wallet_item.syncs.create!
    parent.perform
    child = parent.children.find_by!(syncable: @wallet)
    assert parent.reload.syncing?
    child.perform
    account_sync = child.children.find_by!(syncable: @account)
    assert child.reload.syncing?
    assert parent.reload.syncing?
    assert_equal 100, @account.reload.cash_balance
    SyncJob.perform_now(account_sync)
    assert child.reload.completed?
    assert parent.reload.completed?
    assert_equal 3100, @account.reload.balance
  end

  test "a failed wallet read fails its parent and retains the published account" do
    @wallet.connect!
    before = @account.reload.balance
    parent = @wallet.onchain_wallet_item.syncs.create!
    parent.perform
    child = parent.children.find_by!(syncable: @wallet)
    @provider.stubs(:get_address).raises(ArgumentError, "Incomplete address response")
    child.perform
    assert child.reload.failed?
    assert parent.reload.failed?
    assert @wallet.reload.status_failed?
    assert_equal before, @account.reload.balance
  end

  test "discovery checkpoints are child syncs and keep the root incomplete" do
    BitcoinWalletAccount::Discovery.any_instance.stubs(:perform).returns(false, true)
    parent = @wallet.syncs.create!
    parent.perform
    assert parent.reload.syncing?
    continuation = parent.children.find_by!(syncable: @wallet)
    continuation.perform
    assert continuation.reload.completed?
    assert parent.reload.completed?
    assert @wallet.reload.status_preview?
  end

  test "transient retries remain in the same sync tree" do
    @provider.stubs(:tip_hash).returns("old", "changed", "stable", "stable")
    parent = @wallet.syncs.create!
    parent.perform
    assert parent.reload.syncing?
    retry_sync = parent.children.find_by!(syncable: @wallet)
    assert_equal 1, retry_sync.sync_stats.fetch("read_attempt")
    retry_sync.perform
    assert retry_sync.reload.completed?
    assert parent.reload.completed?
    assert @wallet.reload.status_preview?
  end

  test "independent wallet parents cannot borrow each other's pending read" do
    first = @wallet.onchain_wallet_item.syncs.create!
    second = @wallet.onchain_wallet_item.syncs.create!
    one = @wallet.sync_later(parent_sync: first)
    two = @wallet.sync_later(parent_sync: second)
    refute_equal one.id, two.id
    assert_equal first.id, one.parent_id
    assert_equal second.id, two.parent_id
    assert_equal two.id, @wallet.sync_later(parent_sync: second).id
  end

  test "source changes during a running wallet sync receive a follow-up read" do
    current = @wallet.syncs.create!(status: "syncing")
    @wallet.sources_changed!
    next_sync = @wallet.syncs.pending.first
    assert next_sync
    refute_equal current.id, next_sync.id
  end

  test "advisory lock contention defers completion until its read can run" do
    config = ActiveRecord::Base.connection_pool.db_config.configuration_hash
    key = Digest::SHA256.digest("bitcoin-wallet-sync:#{@wallet.id}").unpack1("q>")
    other = PG.connect(dbname: config[:database], host: config[:host], port: config[:port],
      user: config[:username] || config[:user], password: config[:password])
    other.exec("SELECT pg_advisory_lock(#{key})")
    parent = @wallet.syncs.create!
    parent.perform
    assert_empty @provider.reads
    assert parent.reload.syncing?
    continuation = parent.children.find_by!(syncable: @wallet)
    other.close
    other = nil

    continuation.perform
    assert continuation.reload.completed?
    assert parent.reload.completed?
    assert_equal 30_000_000, @wallet.reload.balance_sats
  ensure
    other&.close
  end

  test "cancellation stops a queued wallet read" do
    parent = @wallet.syncs.create!
    parent.request_cancel!
    @provider.expects(:get_address).never
    parent.perform
    assert parent.reload.stale?
    assert_equal 20_000_000, @wallet.reload.balance_sats
  end

  test "wallet and account child jobs use the same family date across midnight" do
    @wallet.family.update!(timezone: "Pacific/Auckland")
    travel_to Time.utc(2026, 9, 27, 16) do
      Time.use_zone("Pacific/Auckland") do
        @wallet.security.prices.find_or_create_by!(date: Date.current) do |price|
          price.price = 10_000
          price.currency = "USD"
        end
        @wallet.connect!
      end
      parent = @wallet.syncs.create!
      SyncJob.perform_now(parent)
      child = parent.children.find_by!(syncable: @account)
      SyncJob.perform_now(child)
      assert parent.reload.completed?
      assert_equal 3100, @account.reload.balance
      assert_equal Date.new(2026, 9, 28), @account.balances.order(date: :desc).first.date
    end
  end

  test "a baseline transaction returning after a reorg has no false market flow" do
    @wallet.connect!
    @wallet.update!(baseline_block_height: 100)
    tx = bitcoin_transaction(id: "f" * 64, outputs: [ [ RECEIVE, 20_000_000 ] ])
    @wallet.bitcoin_wallet_transactions.create!(txid: tx.fetch("txid"), amount_sats: 20_000_000,
      baseline: true, confirmed: true, block_height: 100, occurred_at: Time.current)
    travel 1.day do
      @provider.fund(RECEIVE, 0)
      BitcoinWalletAccount::Syncer.new(@wallet, provider: @provider).perform
      assert_equal 100, @account.reload.balance
      assert_equal 0, @account.balances.find_by!(date: Date.current).net_market_flows
    end
    travel 2.days do
      @provider.fund(RECEIVE, 20_000_000)
      @provider.transactions[RECEIVE] = [ tx ]
      BitcoinWalletAccount::Syncer.new(@wallet, provider: @provider).perform
      assert_equal 2100, @account.reload.balance
      assert_equal 0, @account.balances.find_by!(date: Date.current).net_market_flows
      assert_equal 0, @account.balances.find_by!(date: Date.current.prev_day).net_market_flows
      assert_empty @account.entries.where(source: "bitcoin_wallet")
    end
  end

  test "RBF across dates corrects prior holdings without false gains" do
    @wallet.connect!
    travel 1.day do
      @provider.fund(RECEIVE, 20_000_000)
      @provider.transactions[RECEIVE] = [ bitcoin_transaction(id: "c" * 64, confirmed: false, outputs: [ [ RECEIVE, 1000 ] ]) ]
      BitcoinWalletAccount::Syncer.new(@wallet, provider: @provider).perform
    end
    travel 2.days do
      @provider.transactions[RECEIVE] = [ bitcoin_transaction(id: "d" * 64, confirmed: false, outputs: [ [ RECEIVE, 2000 ] ]) ]
      BitcoinWalletAccount::Syncer.new(@wallet, provider: @provider).perform
      assert_equal BigDecimal("0.20002"), @wallet.reload.quantity
      assert_equal 0, @account.balances.find_by!(date: Date.current).net_market_flows
      assert_equal 0, @account.balances.find_by!(date: Date.current.prev_day).net_market_flows
      assert_equal 1, @account.entries.where(source: "bitcoin_wallet").count
    end
  end

  test "source changes reconcile coverage without changing cash or creating income" do
    @wallet.connect!
    @wallet.bitcoin_wallet_sources.create!(kind: "address", receive_address: CHANGE)
    @wallet.sources_changed!
    @provider.fund(RECEIVE, 20_000_000)
    @provider.fund(CHANGE, 10_000_000)
    BitcoinWalletAccount::Syncer.new(@wallet, provider: @provider).perform
    assert_equal BigDecimal("0.3"), @wallet.reload.quantity
    assert_equal 100, @account.reload.cash_balance
    assert_equal 0, @account.balances.find_by!(date: Date.current).net_market_flows
    @wallet.bitcoin_wallet_sources.find_by!(receive_address: CHANGE).destroy!
    @wallet.bitcoin_wallet_addresses.destroy_all
    @wallet.sources_changed!
    BitcoinWalletAccount::Syncer.new(@wallet, provider: @provider).perform
    assert_equal BigDecimal("0.2"), @wallet.reload.quantity
    assert_equal 100, @account.reload.cash_balance
    assert_equal 0, @account.balances.find_by!(date: Date.current).net_market_flows
  end
end

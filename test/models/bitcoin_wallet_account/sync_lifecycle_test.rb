require "test_helper"
require "support/bitcoin_wallet_test_helper"

class BitcoinWalletAccount::SyncLifecycleTest < ActiveSupport::TestCase
  include BitcoinWalletTestHelper

  setup do
    @wallet = build_bitcoin_wallet(status: :preview, balance_sats: 20_000_000, last_synced_at: Time.current)
    manual_bitcoin_source(@wallet)
    @provider = FakeProvider.new
    @provider.fund(RECEIVE, 30_000_000)
    Provider::MempoolSpace.stubs(:new).returns(@provider)
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
    assert @wallet.reload.status_preview?
    assert_nil @wallet.last_error
    retry_sync.perform
    assert retry_sync.reload.completed?
    assert parent.reload.completed?
    assert @wallet.reload.status_preview?
  end

  test "an explorer rate limit is retried after a minute" do
    @provider.stubs(:get_address).raises(Provider::MempoolSpace::RateLimitError)
    SyncJob.expects(:set).with(wait: 1.minute).returns(stub(perform_later: true))
    parent = @wallet.syncs.create!
    parent.perform
    assert parent.reload.syncing?
    refute @wallet.reload.status_failed?
  end

  test "a transient error that outlasts its retries fails the wallet" do
    @provider.stubs(:tip_hash).returns(*%w[a b c d e f])
    sync = @wallet.syncs.create!
    sync.perform
    2.times do
      sync = sync.children.find_by!(syncable: @wallet)
      sync.perform
    end
    assert sync.reload.failed?
    assert @wallet.reload.status_failed?
    assert_equal "BitcoinWalletAccount::Snapshot::ChangedTip", @wallet.last_error
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

  test "a sync waiting on another read backs off and reuses its result" do
    config = ActiveRecord::Base.connection_pool.db_config.configuration_hash
    key = Digest::SHA256.digest("bitcoin-wallet-sync:#{@wallet.id}").unpack1("q>")
    other = PG.connect(dbname: config[:database], host: config[:host], port: config[:port],
      user: config[:username] || config[:user], password: config[:password])
    other.exec("SELECT pg_advisory_lock(#{key})")
    parent = @wallet.syncs.create!
    parent.perform
    waiting = parent.children.find_by!(syncable: @wallet)
    assert_equal 1, waiting.sync_stats.fetch("lock_waits")
    waiting.perform
    waiting = waiting.children.find_by!(syncable: @wallet)
    assert_equal 2, waiting.sync_stats.fetch("lock_waits")
    other.close
    other = nil

    @wallet.update!(last_synced_at: Time.current)
    waiting.perform
    assert_empty @provider.reads
    assert parent.reload.completed?
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
end

require "test_helper"
require "support/bitcoin_wallet_test_helper"

class BitcoinWalletAccount::PublicationLifecycleTest < ActiveSupport::TestCase
  include BitcoinWalletTestHelper

  setup do
    @account = accounts(:crypto)
    @account.entries.destroy_all
    @account.holdings.destroy_all
    @account.balances.destroy_all
    @account.update!(cash_balance: 100, balance: 100)
    # Deposited cash, not a typed value of the coins, so connecting keeps it.
    # Dated before every travel_to below.
    @account.entries.create!(date: Date.new(2026, 9, 1), amount: -100, currency: "USD", name: "Deposit",
      entryable: Transaction.new)
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

  test "an unconnected draft stays out of the shared connection sync" do
    parent = @wallet.onchain_wallet_item.syncs.create!
    parent.perform
    assert_nil parent.children.find_by(syncable: @wallet)
    assert parent.reload.completed?
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

  test "source reconciliation leaves the original ownership date intact" do
    before_connection = Account::ProviderImportAdapter.new(@account).import_trade(
      security: @wallet.security, quantity: 0.1, price: 10_000, amount: 0,
      currency: "USD", date: Date.current.prev_day, source: "manual")
    @wallet.connect!

    imported = travel(1.day) do
      @provider.fund(RECEIVE, 20_000_000)
      @provider.transactions[RECEIVE] = [ bitcoin_transaction(confirmed: false, outputs: [ [ RECEIVE, 1000 ] ]) ]
      BitcoinWalletAccount::Syncer.new(@wallet, provider: @provider).perform
      @account.entries.find_by!(source: "bitcoin_wallet")
    end

    travel 2.days do
      @wallet.bitcoin_wallet_sources.create!(kind: "address", receive_address: CHANGE)
      @wallet.sources_changed!
      BitcoinWalletAccount::Syncer.new(@wallet, provider: @provider).perform

      assert_equal Date.current, @wallet.reload.baseline_at.to_date
      refute imported.reload.update(amount: 1)
      refute imported.destroy
      assert before_connection.reload.update(amount: 1)
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
    @wallet.sources_changed!
    BitcoinWalletAccount::Syncer.new(@wallet, provider: @provider).perform
    assert_equal BigDecimal("0.2"), @wallet.reload.quantity
    assert_equal 100, @account.reload.cash_balance
    assert_equal 0, @account.balances.find_by!(date: Date.current).net_market_flows
  end
end

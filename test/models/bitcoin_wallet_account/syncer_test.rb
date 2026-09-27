require "test_helper"
require "support/bitcoin_wallet_test_helper"

class BitcoinWalletAccount::SyncerTest < ActiveSupport::TestCase
  include BitcoinWalletTestHelper

  setup do
    @wallet = build_bitcoin_wallet
    manual_bitcoin_source(@wallet)
    @provider = FakeProvider.new
  end

  test "a complete draft read is a preview and does not update the account" do
    before = @wallet.account.balance
    @provider.fund(RECEIVE, 1_234_567)
    BitcoinWalletAccount::Syncer.new(@wallet, provider: @provider).perform
    assert @wallet.reload.status_preview?
    assert_equal 1_234_567, @wallet.balance_sats
    assert_equal before, @wallet.account.reload.balance
    refute @wallet.account.linked?
  end

  test "a failed read preserves the last complete amount" do
    @wallet.update!(balance_sats: 123)
    @provider.stubs(:get_address).raises(Provider::MempoolSpace::ApiError)
    assert_raises(Provider::MempoolSpace::ApiError) do
      BitcoinWalletAccount::Syncer.new(@wallet, provider: @provider).perform
    end
    assert_equal 123, @wallet.reload.balance_sats
    assert @wallet.status_failed?
  end

  test "confirmation updates a pending transfer rather than adding another one" do
    tx = bitcoin_transaction(confirmed: false, outputs: [ [ RECEIVE, 100 ] ])
    @provider.transactions[RECEIVE] = [ tx ]
    BitcoinWalletAccount::Syncer.new(@wallet, provider: @provider).perform
    assert_equal 1, @wallet.bitcoin_wallet_transactions.count
    @provider.fund(RECEIVE, 100)
    tx["status"] = { "confirmed" => true, "block_height" => 100, "block_time" => Time.current.to_i }
    @provider.statuses[tx["txid"]] = tx["status"]
    BitcoinWalletAccount::Syncer.new(@wallet, provider: @provider).perform
    assert_equal 1, @wallet.bitcoin_wallet_transactions.count
    assert @wallet.bitcoin_wallet_transactions.first.confirmed?
    assert_equal 100, @wallet.reload.balance_sats
  end

  test "RBF removes only the replaced wallet entry and retains the new transfer once" do
    @wallet.update!(status: :preview, last_synced_at: Time.current)
    @wallet.connect!
    first = bitcoin_transaction(id: "c" * 64, confirmed: false, outputs: [ [ RECEIVE, 100 ] ])
    @provider.transactions[RECEIVE] = [ first ]
    BitcoinWalletAccount::Syncer.new(@wallet, provider: @provider).perform
    replacement = bitcoin_transaction(id: "d" * 64, confirmed: false, outputs: [ [ RECEIVE, 200 ] ])
    @provider.transactions[RECEIVE] = [ replacement ]
    BitcoinWalletAccount::Syncer.new(@wallet, provider: @provider).perform
    entries = @wallet.account.entries.where(source: "bitcoin_wallet")
    assert_equal 1, entries.count
    assert_includes entries.first.external_id, "d" * 64
    assert_equal 200, @wallet.reload.balance_sats
    refute @wallet.bitcoin_wallet_transactions.find_by!(txid: "c" * 64).present?
  end

  test "a disappeared pending deposit restores the balance without removing manual records" do
    @wallet.update!(status: :preview, last_synced_at: Time.current)
    @wallet.connect!
    tx = bitcoin_transaction(id: "e" * 64, confirmed: false, outputs: [ [ RECEIVE, 100 ] ])
    @provider.transactions[RECEIVE] = [ tx ]
    BitcoinWalletAccount::Syncer.new(@wallet, provider: @provider).perform
    manual = @wallet.account.entries.create!(date: Date.current, amount: 0, currency: "USD", name: "Manual note", entryable: Transaction.new)
    @provider.transactions[RECEIVE] = []
    BitcoinWalletAccount::Syncer.new(@wallet, provider: @provider).perform
    assert_equal 0, @wallet.reload.balance_sats
    assert_empty @wallet.account.entries.where(source: "bitcoin_wallet")
    assert Entry.exists?(manual.id)
  end

  test "a reorg rolls back the provider's confirmed transfer" do
    @wallet.update!(status: :preview, last_synced_at: Time.current)
    @wallet.connect!
    tx = bitcoin_transaction(id: "f" * 64, outputs: [ [ RECEIVE, 100 ] ])
    @provider.fund(RECEIVE, 100)
    @provider.transactions[RECEIVE] = [ tx ]
    BitcoinWalletAccount::Syncer.new(@wallet, provider: @provider).perform
    @provider.fund(RECEIVE, 0)
    @provider.transactions[RECEIVE] = []
    @provider.statuses[tx["txid"]] = { "confirmed" => false }
    BitcoinWalletAccount::Syncer.new(@wallet, provider: @provider).perform
    assert_equal 0, @wallet.reload.balance_sats
    assert_empty @wallet.account.entries.where(source: "bitcoin_wallet")
  end

  test "a source change during HTTP invalidates the result without changing the balance" do
    @wallet.update!(balance_sats: 123)
    original = @provider.method(:get_address)
    wallet = @wallet
    @provider.define_singleton_method(:get_address) do |address|
      unless @changed
        wallet.bitcoin_wallet_sources.create!(kind: "address", receive_address: BitcoinWalletTestHelper::CHANGE)
        @changed = true
      end
      original.call(address)
    end
    BitcoinWalletAccount::Syncer.new(@wallet, provider: @provider).perform
    assert_equal 123, @wallet.reload.balance_sats
    assert_nil @wallet.last_synced_at
  end

  test "a held advisory lock coalesces concurrent readers" do
    config = ActiveRecord::Base.connection_pool.db_config.configuration_hash
    key = Digest::SHA256.digest("bitcoin-wallet-sync:#{@wallet.id}").unpack1("q>")
    other = PG.connect(dbname: config[:database], host: config[:host], port: config[:port],
      user: config[:username] || config[:user], password: config[:password])
    other.exec("SELECT pg_advisory_lock(#{key})")
    @provider.expects(:get_address).never
    BitcoinWalletAccount::Syncer.new(@wallet, provider: @provider).perform
    assert_nil @wallet.reload.last_synced_at
  ensure
    other&.close
  end

  test "a financial reset removes draft wallet descendants safely" do
    PlaidItem.any_instance.stubs(:remove_plaid_item).returns(true)
    @wallet.bitcoin_wallet_addresses.create!(address: RECEIVE)
    @wallet.bitcoin_wallet_transactions.create!(txid: "f" * 64, amount_sats: 100, occurred_at: Time.current)
    id = @wallet.id
    Family::FinancialDataReset.new(family: @wallet.family, dry_run: false, confirmed: true).call
    refute BitcoinWalletAccount.exists?(id)
    assert_empty BitcoinWalletSource.where(bitcoin_wallet_account_id: id)
    assert_empty BitcoinWalletAddress.where(bitcoin_wallet_account_id: id)
    assert_empty BitcoinWalletTransaction.where(bitcoin_wallet_account_id: id)
  end
end

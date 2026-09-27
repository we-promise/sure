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
end

require "test_helper"
require Rails.root.join("test/support/ca_auto_bank_test_helper")

class CaAutoBankItem::ImporterTest < ActiveSupport::TestCase
  include CaAutoBankTestHelper

  setup do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    Account.any_instance.stubs(:sync_later)
    @item = ca_connected_item
    @importer = CaAutoBankItem::Importer.new(@item)
  end

  test "imports Libero and each CD once using principal only and native provider links" do
    snapshot = ca_snapshot(@item)
    assert_difference [ "Account.count", "AccountProvider.count", "CaAutoBankAccount.count" ], 3 do
      @importer.import(snapshot: snapshot)
    end
    assert_no_difference [ "Account.count", "AccountProvider.count", "CaAutoBankAccount.count", "Entry.count" ] do
      @importer.import(snapshot: snapshot)
    end
    assert_equal BigDecimal("3125"), @item.accounts.sum(:balance)
    assert @item.accounts.all? { |account| account.cash_balance == account.balance }
    assert_equal %w[cd cd savings], @item.accounts.map { |account| account.accountable.subtype }.sort
    assert @item.accounts.all? { |account| account.institution_name == "CA Auto Bank" && account.owner == @item.owner && account.currency == "EUR" }
    assert_equal 0, @item.accounts.joins(:entries).where(entries: { entryable_type: "Transaction" }).count
    refute_includes @item.ca_auto_bank_accounts.map(&:deposit_metadata).to_json, "private-deposit"
    assert @item.accounts.all? { |account| account.history_start_date == snapshot.observed_at.in_time_zone("Europe/Rome").to_date }
  end

  test "partial duplicate malformed or mismatched deposits preserve the entire preceding snapshot" do
    @importer.import(snapshot: ca_snapshot(@item))
    initial = @item.accounts.order(:id).pluck(:id, :balance)
    mutations = [
      ->(bundle) { bundle["overview"]["restrictedBalance"] = 1 },
      ->(bundle) { bundle["deposits"].pop },
      ->(bundle) { bundle["deposits"][1]["summary"]["operationNumber"] = 1 },
      ->(bundle) { bundle["deposits"][0]["details"]["amount"] = -10 },
      ->(bundle) { bundle["deposits"][0]["summary"]["maturityDate"] = "2028-02-30" }
    ]
    mutations.each do |mutation|
      snapshot = ca_snapshot(@item, cash: 250)
      mutation.call(snapshot.reports.sole)
      assert_raises(Provider::CaAutoBank::Error) { @importer.import(snapshot: snapshot) }
      assert_equal initial, @item.accounts.order(:id).pluck(:id, :balance)
    end
  end

  test "complete maturity snapshots move principal to Libero without counting the missing CD twice" do
    @importer.import(snapshot: ca_snapshot(@item))
    @importer.import(snapshot: ca_snapshot(@item, cash: 3125, deposits: []))
    assert_equal BigDecimal("3125"), @item.accounts.sum(:balance)
    assert @item.accounts.all? { |account| account.cash_balance == account.balance }
    assert_equal [ 0.to_d, 0.to_d ], @item.ca_auto_bank_accounts.where(kind: "time_deposit").pluck(:current_balance)
    assert_equal [ "NOT_ACTIVE" ], @item.ca_auto_bank_accounts.where(kind: "time_deposit").map { |row| row.deposit_metadata["status"] }.uniq
  end

  test "changed cash is reflected in both account balance fields without creating income" do
    @importer.import(snapshot: ca_snapshot(@item))
    @importer.import(snapshot: ca_snapshot(@item, cash: 250))
    cash_account = @item.ca_auto_bank_accounts.find_by!(kind: "libero").account
    assert_equal BigDecimal("250"), cash_account.balance
    assert_equal BigDecimal("250"), cash_account.cash_balance
    assert_empty cash_account.entries.where(entryable_type: "Transaction")
  end

  test "unlink or a different owner blocks automatic relinking and rolls back other balance changes" do
    @importer.import(snapshot: ca_snapshot(@item))
    row = @item.ca_auto_bank_accounts.where(kind: "time_deposit").first
    row.account_provider.destroy!
    assert_no_difference [ "Account.count", "AccountProvider.count" ] do
      assert_raises(Provider::CaAutoBank::Error) { @importer.import(snapshot: ca_snapshot(@item, cash: 500)) }
    end
    assert_equal BigDecimal("125"), @item.ca_auto_bank_accounts.find_by!(kind: "libero").account.balance
  end

  test "old snapshots or responses from a disconnected session cannot overwrite balances" do
    @importer.import(snapshot: ca_snapshot(@item))
    old = ca_snapshot(@item, cash: 999, observed_at: 1.hour.ago)
    error = assert_raises(Provider::CaAutoBank::Error) { @importer.import(snapshot: old) }
    assert_equal "stale_snapshot", error.code
    stale_session = ca_snapshot(@item, cash: 999)
    @item.disconnect!
    error = assert_raises(Provider::CaAutoBank::Error) { @importer.import(snapshot: stale_session) }
    assert_equal "account_identity_changed", error.code
    assert_equal BigDecimal("3125"), @item.accounts.sum(:balance)
  end

  test "disconnect preserves saved accounts and balances" do
    @importer.import(snapshot: ca_snapshot(@item))
    ids = @item.accounts.ids.sort
    @item.disconnect!
    assert_equal ids, @item.accounts.ids.sort
    assert_equal BigDecimal("3125"), @item.accounts.sum(:balance)
    assert @item.reload.requires_update?
  end
end

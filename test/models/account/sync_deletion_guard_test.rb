require "test_helper"

class Account::SyncDeletionGuardTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  teardown { clear_enqueued_jobs }

  test "an empty sealed calculation remains disposable ordinary history" do
    account = create_account
    identity = Account::IngestionIdentity.capture!(account: account)
    sync = account.sync_later
    assert sync.account_inputs_sealed_at
    assert_empty sync.account_sync_inputs

    account.destroy!

    refute Account.exists?(account.id)
    refute Sync.exists?(sync.id)
    refute Account::IngestionIdentity.exists?(identity.id)
  end

  test "materialization evidence refuses direct deletion before dependent cleanup" do
    account = create_account
    sync = account.sync_later
    sync.update!(account_materialized_at: Time.current)
    original = sync.reload.attributes
    account.expects(:cleanup_transfers).never

    refute account.destroy

    assert Account.exists?(account.id)
    assert account.errors[:base].any?
    assert_equal original, sync.reload.attributes
  end

  test "materialization evidence refuses scheduled deletion and restores the active state" do
    account = create_account
    sync = account.sync_later
    sync.update!(account_materialized_at: Time.current)
    original = sync.reload.attributes
    clear_enqueued_jobs

    assert_no_enqueued_jobs do
      assert_raises(ActiveRecord::RecordNotDestroyed) { account.destroy_later }
    end

    assert account.reload.active?
    assert_equal original, sync.reload.attributes
  end

  test "an ancestor cannot erase a retired child even without batch or selected-input restrictions" do
    account = create_account
    parent = account.family.syncs.create!
    child = account.syncs.create!(parent: parent)
    retire_without_financial_inputs(account)
    original = [ parent.reload.attributes, child.reload.attributes ]

    assert_raises(ActiveRecord::StatementInvalid) do
      Sync.transaction(requires_new: true) { parent.destroy! }
    end

    assert_equal original, [ Sync.find(parent.id).attributes, Sync.find(child.id).attributes ]
  end

  test "the family FK can erase retired empty history only when the entire owning family is removed" do
    family = Family.create!(name: "Isolated history erase")
    account = family.accounts.create!(name: "Retired empty owner", currency: "USD", balance: 0, accountable: Depository.new)
    sync = account.syncs.create!
    retire_without_financial_inputs(account)

    # This tests the FK boundary with no other financial/provider dependencies.
    # It is not a native whole-family erasure implementation.
    Family.where(id: family.id).delete_all

    refute Family.exists?(family.id)
    refute Account::IngestionIdentity.exists?(account.id)
    refute Sync.exists?(sync.id)
  end

  private
    def retire_without_financial_inputs(account)
      Account::IngestionIdentity.capture!(account: account)
      Account::IngestionIdentity.where(id: account.id).update_all(live_account_id: nil, retired_at: Time.current)
      Account.where(id: account.id).delete_all
      ApplicationRecord.connection.execute("SET CONSTRAINTS account_ingestion_identity_retirement IMMEDIATE")
      ApplicationRecord.connection.execute("SET CONSTRAINTS account_ingestion_identity_retirement DEFERRED")
    end

    def create_account
      families(:empty).accounts.create!(name: "Calculation deletion", currency: "USD",
        balance: 100, cash_balance: 100, status: "active", accountable: Depository.new)
    end
end

require "test_helper"

class EntrySyncCommitTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  test "a request without an open transaction schedules immediately" do
    with_entry do |entry, account|
      assert_enqueued_with(job: SyncJob) { entry.sync_account_later }

      assert_equal entry.date, account.syncs.sole.window_start_date
    end
  end

  test "financial edits schedule only after their outer transaction commits" do
    with_entry do |entry, account|
      original_date = entry.date
      assert_enqueued_with(job: SyncJob) do
        Entry.transaction do
          entry.update!(date: original_date + 1)
          Entry.transaction(requires_new: true) { entry.sync_account_later }
          entry.lock_saved_attributes!
          entry.mark_user_modified!

          assert_empty account.syncs
          assert_no_enqueued_jobs(only: SyncJob)
        end
      end

      assert entry.reload.user_modified?
      assert_equal original_date, account.syncs.reload.sole.window_start_date
    end
  end

  test "rollback discards the sync request and its account row write" do
    with_entry do |entry, account|
      original_date = entry.date
      assert_no_enqueued_jobs(only: SyncJob) do
        Entry.transaction do
          entry.update!(date: original_date - 1)
          entry.sync_account_later
          raise ActiveRecord::Rollback
        end
      end

      assert_equal original_date, entry.reload.date
      assert_empty account.syncs
    end
  end

  test "a rolled back savepoint does not schedule when its outer transaction commits" do
    with_entry do |entry, account|
      assert_no_enqueued_jobs(only: SyncJob) do
        Entry.transaction do
          Entry.transaction(requires_new: true) do
            entry.update!(date: entry.date - 1)
            entry.sync_account_later
            raise ActiveRecord::Rollback
          end
        end
      end

      assert_empty account.syncs
    end
  end

  test "the date window is captured before later saves replace the change history" do
    with_entry do |entry, account|
      earlier_date = entry.date - 2
      Entry.transaction do
        entry.update!(date: earlier_date)
        entry.sync_account_later
        entry.update!(notes: "Another save")
        entry.date = earlier_date - 10
      end

      assert_equal earlier_date, entry.reload.date
      assert_equal earlier_date, account.syncs.sole.window_start_date
    end
  end

  test "the scheduled account cannot change with a later in-memory association assignment" do
    with_entry do |entry, account|
      other = account.family.accounts.create!(name: "Other account", currency: "USD", balance: 0, accountable: Depository.new)
      Entry.transaction do
        entry.sync_account_later
        entry.account = other
      end

      assert_equal 1, account.syncs.count
      assert_empty other.syncs
    end
  end

  test "a committed Entry deletion requests the existing full account window" do
    with_entry do |entry, account|
      assert_enqueued_with(job: SyncJob) do
        Entry.transaction do
          entry.destroy!
          entry.sync_account_later
          assert_empty account.syncs
        end
      end

      assert_nil account.syncs.reload.sole.window_start_date
    end
  end

  test "deleting the Account before commit discards an earlier Entry sync request" do
    with_entry do |entry, account|
      assert_no_enqueued_jobs(only: SyncJob) do
        Entry.transaction do
          entry.sync_account_later
          # A different instance makes the original captured object stale.
          Account.find(account.id).destroy!
        end
      end

      assert_not Account.exists?(account.id)
      assert_not Sync.exists?(syncable_type: "Account", syncable_id: account.id)
    end
  end

  private
    def with_entry
      family = Family.create!(name: "Entry sync commits", currency: "USD")
      account = family.accounts.create!(name: "Checking", currency: "USD", balance: 0, accountable: Depository.new)
      entry = account.entries.create!(name: "Edit me", date: Date.current - 5, amount: 10, currency: "USD", entryable: Transaction.new)
      clear_enqueued_jobs
      yield entry, account
    ensure
      family.destroy! if family&.persisted? && Family.exists?(family.id)
      clear_enqueued_jobs
    end
end

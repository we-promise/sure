require "test_helper"

# Separate connections need committed records so the user edit and the sync
# can observe each other without changing fixtures shared by other tests.
class Entry::SaveAndLockConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @family = Family.create!(name: "Save and lock race", currency: "USD")
    @category = Category.create!(family: @family, name: "Provider", color: "#0d9488", lucide_icon: "tag")
    @user_category = Category.create!(family: @family, name: "User", color: "#0d9488", lucide_icon: "tag")
    @account = Account.create!(
      family: @family, name: "Checking", currency: "USD",
      balance: 0, accountable: Depository.new
    )
    @entry = Entry.create!(
      account: @account, name: "Provider name", date: Date.current,
      amount: 10, currency: "USD", external_id: "race-1", source: "simplefin",
      entryable: Transaction.new
    )
  end

  teardown do
    if @entry
      DataEnrichment.where(enrichable_type: "Entry", enrichable_id: @entry.id).delete_all
      DataEnrichment.where(enrichable_type: "Transaction", enrichable_id: @entry.entryable_id).delete_all
      Entry.where(id: @entry.id).delete_all
      Transaction.where(id: @entry.entryable_id).delete_all
    end
    Category.where(family_id: @family.id).delete_all if @family
    if @account
      Sync.where(syncable: @account).delete_all
      Account.where(id: @account.id).delete_all
      Depository.where(id: @account.accountable_id).delete_all
    end
    Rule.where(family_id: @family.id).destroy_all if @family
    Family.where(id: @family.id).delete_all if @family
  end

  test "a provider sync waits for a user edit in progress and keeps it" do
    race_with_user_edit(
      edit: ->(entry) { entry.update(name: "User name") },
      sync: -> {
        Account::ProviderImportAdapter.new(@account).import_transaction(
          external_id: "race-1", amount: 10, currency: "USD", date: Date.current,
          name: "Renamed by provider", source: "simplefin"
        )
      }
    )

    @entry.reload
    assert_equal "User name", @entry.name
    assert @entry.locked?(:name)
    assert @entry.user_modified?
  end

  test "a rule waits for a user edit in progress and keeps its category" do
    stale_transaction = Transaction.find(@entry.entryable_id)

    race_with_user_edit(
      edit: ->(entry) { entry.update(entryable_attributes: { id: entry.entryable_id, category_id: @user_category.id }) },
      sync: -> { stale_transaction.enrich_attribute(:category_id, @category.id, source: "rule") }
    )

    transaction = @entry.reload.transaction
    assert_equal @user_category.id, transaction.category_id
    assert transaction.locked?(:category_id)
  end

  test "an edit of a tagged entry and a rule on its transaction do not deadlock" do
    tag = Tag.create!(family: @family, name: "Race")
    @entry.transaction.update!(tag_ids: [ tag.id ])
    stale_transaction = Transaction.find(@entry.entryable_id)

    # The edit writes only the entry, then locks its tags on the transaction;
    # the rule writes the transaction, then touches the entry.
    race_with_user_edit(
      edit: ->(entry) { entry.update(notes: "User note") },
      sync: -> { stale_transaction.enrich_attribute(:category_id, @category.id, source: "rule") },
      lock_tags: :if_any
    )

    @entry.reload
    assert_equal "User note", @entry.notes
    assert @entry.transaction.locked?(:tag_ids)
    assert_equal @category.id, @entry.transaction.category_id
  ensure
    Tagging.where(tag: tag).delete_all if tag
    Tag.where(id: tag.id).delete_all if tag
  end

  private
    # Runs the user's save in one connection and pauses it before the locks are
    # written. The sync runs in another connection meanwhile; the edit
    # continues once the sync waits on it (or has finished without waiting).
    def race_with_user_edit(edit:, sync:, lock_tags: nil)
      pool = ActiveRecord::Base.connection_pool
      assert_operator pool.size, :>=, 3, "race regression needs user, sync and observer connections"
      observer = Entry.connection
      saved = Queue.new
      resume = Queue.new
      sync_pids = Queue.new
      sync_thread = nil

      user_thread = Thread.new do
        pool.with_connection do |connection|
          connection.execute("SET statement_timeout = '30s'")
          entry = Entry.find(@entry.id)
          entry.save_and_lock_attributes(user_modified: true, lock_tags: lock_tags) do
            edit.call(entry).tap do
              saved << connection.select_value("SELECT pg_backend_pid()")
              resume.pop
            end
          end
        ensure
          connection.execute("SET statement_timeout = 0")
        end
      end
      user_thread.report_on_exception = false
      user_pid = pop_with_timeout(saved, user_thread, "user edit did not save")

      sync_thread = Thread.new do
        pool.with_connection do |connection|
          connection.execute("SET statement_timeout = '30s'")
          sync_pids << connection.select_value("SELECT pg_backend_pid()")
          sync.call
        ensure
          connection.execute("SET statement_timeout = 0")
        end
      end
      sync_thread.report_on_exception = false
      sync_pid = pop_with_timeout(sync_pids, sync_thread, "sync did not start")

      wait_until_blocked_or_done(observer, sync_thread, sync_pid, user_pid)
      resume << true

      assert user_thread.join(10), "user edit did not finish"
      assert sync_thread.join(10), "sync did not finish after the user edit committed"
      assert user_thread.value, "user edit was not saved"
      sync_thread.value
    ensure
      resume << true
      [ user_thread, sync_thread ].compact.each { |thread| thread.kill unless thread.join(5) }
    end

    def pop_with_timeout(queue, thread, message)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      loop do
        return queue.pop unless queue.empty?
        unless thread.alive?
          thread.value # Propagate the thread's failure instead of a timeout.
          flunk message
        end
        flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end
    end

    def wait_until_blocked_or_done(observer, sync_thread, sync_pid, user_pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      loop do
        return unless sync_thread.alive?

        blocked = observer.uncached do
          observer.select_value("SELECT #{Integer(user_pid)} = ANY(pg_blocking_pids(#{Integer(sync_pid)}))")
        end
        return if blocked

        flunk "sync neither finished nor waited on the user edit" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end
    end
end

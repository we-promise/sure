require "test_helper"
require "timeout"

# An import is as private as its statement, so deleting a statement must never
# leave an import without it. The model checks for imports before the DELETE,
# with no lock, so an import committed in between is caught only by the foreign
# key: its lock on the statement row makes the DELETE and the INSERT wait for
# each other, whichever comes first.
#
# Real threads on real connections, so this needs real commits.
class AccountStatementImportConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "statement-#{SecureRandom.hex(4)}.csv", content_type: "text/csv",
                          content: "date,amount\n2024-01-01,#{SecureRandom.hex(4)}\n")
    )
    @threads = []
  end

  teardown do
    # Each test has already read its threads' outcomes; join re-raises them.
    @threads.each do |thread|
      thread.join(10)
    rescue StandardError
      nil
    ensure
      thread.kill if thread.alive?
    end
    Import.where(account_statement_id: @statement.id).destroy_all
    if AccountStatement.exists?(@statement.id)
      @statement.original_file.purge
      AccountStatement.where(id: @statement.id).delete_all
    end
  end

  test "a statement deleted while an import for it is being created stays, and so does the import's reference" do
    inserted = Queue.new
    release = Queue.new
    import_id = Queue.new
    creator = in_thread do
      Import.transaction do
        import_id << TransactionImport.create!(family: @family, account: @account, account_statement: @statement).id
        inserted << true
        release.pop
      end
    end
    Timeout.timeout(10) { inserted.pop }

    deleter_pid = Queue.new
    deleter = in_thread do |connection|
      deleter_pid << connection.select_value("SELECT pg_backend_pid()")
      AccountStatement.find(@statement.id).destroy
    end

    assert_waits_on_lock deleter, Timeout.timeout(10) { deleter_pid.pop }
    release << true
    assert creator.join(10)
    assert_raises(ActiveRecord::InvalidForeignKey) { deleter.value }

    assert AccountStatement.exists?(@statement.id)
    assert_equal @statement.id, Import.find(import_id.pop).account_statement_id
  end

  test "an import created while its statement is being deleted is refused" do
    deleted = Queue.new
    release = Queue.new
    deleter = in_thread do
      AccountStatement.transaction do
        AccountStatement.find(@statement.id).destroy!
        deleted << true
        release.pop
      end
    end
    Timeout.timeout(10) { deleted.pop }

    creator_pid = Queue.new
    creator = in_thread do |connection|
      creator_pid << connection.select_value("SELECT pg_backend_pid()")
      TransactionImport.create!(family: @family, account: @account, account_statement: @statement)
    end

    assert_waits_on_lock creator, Timeout.timeout(10) { creator_pid.pop }
    release << true
    assert deleter.join(10)
    assert_raises(ActiveRecord::InvalidForeignKey) { creator.value }

    assert_not AccountStatement.exists?(@statement.id)
    assert_not Import.exists?(account_statement_id: @statement.id)
  end

  private
    # Thread#value re-raises what the block raised, so each test asserts on
    # the outcome of its own connection.
    def in_thread(&block)
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection(&block)
      end
      thread.report_on_exception = false
      @threads << thread
      thread
    end

    # The thread cannot finish while the other transaction is open, and
    # Postgres reports the wait as soon as it starts.
    def assert_waits_on_lock(thread, pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      loop do
        flunk "finished without waiting for the other transaction" if thread.join(0.01)
        wait_event_type = ActiveRecord::Base.connection.select_value(
          "SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}"
        )
        break if wait_event_type == "Lock"
        flunk "never waited on the other transaction's lock" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      end
    end
end

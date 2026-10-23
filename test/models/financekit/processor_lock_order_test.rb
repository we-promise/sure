require "test_helper"
require "timeout"

class Financekit::ProcessorLockOrderTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @family = Family.create!(name: "FinanceKit lock order", currency: "USD")
    @account = @family.accounts.create!(name: "Checking", currency: "USD", balance: 1000, accountable: Depository.new)
    @entry = @account.entries.create!(
      name: "Edited pending", amount: 100, currency: "USD", date: Date.current, user_modified: true,
      entryable: Transaction.new(extra: { "financekit" => { "pending" => true } })
    )
  end

  teardown do
    begin
      @worker&.join(5)
    ensure
      if @worker&.alive?
        @worker.kill
        @worker.join
      end
      @account.entries.each(&:destroy!)
      @account.destroy!
      @family.destroy!
    end
  end

  test "settling an edited pending entry waits for its transaction before locking the entry" do
    @entry.transaction.with_lock do
      ready = Queue.new
      entry_id = @entry.id
      @worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          entry = Entry.find(entry_id)
          ready << connection.select_value("SELECT pg_backend_pid()")
          Financekit::Processor.new(nil).send(:settle_edited_pending_entry!, entry, { "status" => "booked" })
        end
      end
      worker_pid = Timeout.timeout(5) { ready.pop }
      Timeout.timeout(5) do
        loop do
          blocked = ActiveRecord::Base.uncached do
            ActiveRecord::Base.connection.select_value(
              "SELECT cardinality(pg_blocking_pids(#{Integer(worker_pid)})) > 0")
          end
          break if blocked
          assert @worker.alive?, "settlement completed without waiting for the transaction lock"
          sleep 0.01
        end
      end

      assert_nothing_raised { Entry.where(id: @entry.id).lock("FOR UPDATE NOWAIT").load }
    end

    Timeout.timeout(5) { @worker.value }
    assert_not @entry.transaction.reload.pending?
    assert_equal "Edited pending", @entry.reload.name
    assert @entry.user_modified?
  end
end

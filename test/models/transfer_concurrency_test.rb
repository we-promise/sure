require "test_helper"
require "timeout"

class TransferConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @family = Family.create!(name: "Transfer concurrency", currency: "USD")
    @from_account = @family.accounts.create!(name: "Checking", currency: "USD", balance: 1000, accountable: Depository.new)
    @to_account = @family.accounts.create!(name: "Savings", currency: "USD", balance: 1000, accountable: Depository.new)
    @purchase = @from_account.entries.create!(name: "Purchase", amount: 1000, currency: "USD", date: Date.current, entryable: Transaction.new)
    @counterpart = @to_account.entries.create!(name: "Transfer in", amount: -1000, currency: "USD", date: Date.current, entryable: Transaction.new)
    @credit = @from_account.entries.create!(name: "Return", amount: -800, currency: "USD", date: Date.current, entryable: Transaction.new)
  end

  teardown do
    begin
      @worker&.join(5)
    ensure
      if @worker&.alive?
        @worker.kill
        @worker.join
      end
      transaction_ids = [ @purchase.entryable_id, @counterpart.entryable_id ]
      Transfer
        .where("inflow_transaction_id IN (?) OR outflow_transaction_id IN (?)", transaction_ids, transaction_ids)
        .delete_all
      Entry.where(account_id: [ @from_account.id, @to_account.id ]).delete_all
      @from_account.delete
      @to_account.delete
      @family.destroy!
    end
  end

  test "a transfer waits for an in-flight refund and rejects the refunded purchase" do
    @purchase.transaction.with_lock do
      start_worker { -> { create_transfer } }
      assert_worker_waits_for_lock
      @credit.transaction.mark_as_refund!(purchase: @purchase.transaction)
    end

    assert_equal :rejected, worker_result
    assert @rejection_errors.any? { |error| error[:error] == :refund_links_present }
    assert_equal 0, Transfer.where(outflow_transaction_id: @purchase.entryable_id).count
    assert @credit.transaction.reload.refund?
    assert @purchase.transaction.reload.standard?
  end

  test "a refund waits for an in-flight transfer and rejects the purchase" do
    @purchase.transaction.with_lock do
      start_worker do
        -> do
          Transaction.find(@credit.entryable_id)
            .mark_as_refund!(purchase: Transaction.find(@purchase.entryable_id))
        end
      end
      assert_worker_waits_for_lock
      create_transfer
    end

    assert_equal :rejected, worker_result
    assert @rejection_errors.any? { |error| %i[invalid invalid_refund].include?(error[:error]) }
    assert_equal 1, Transfer.where(outflow_transaction_id: @purchase.entryable_id).count
    assert_not @credit.transaction.reload.refund?
  end

  private
    def create_transfer
      purchase = Transaction.find(@purchase.entryable_id)
      counterpart = Transaction.find(@counterpart.entryable_id)

      Transfer.transaction do
        [ purchase, counterpart ].sort_by(&:id).each(&:lock!)
        transfer = Transfer.new(outflow_transaction: purchase, inflow_transaction: counterpart)
        transfer.save!
        transfer.confirm!
        transfer
      end
    end

    def start_worker
      ready = Queue.new
      @worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          operation = yield
          ready << connection.select_value("SELECT pg_backend_pid()")
          operation.call
          :completed
        rescue ActiveRecord::RecordInvalid => error
          @rejection_errors = error.record.errors.details.values.flatten
          :rejected
        end
      end
      @worker_pid = Timeout.timeout(5) { ready.pop }
    end

    def assert_worker_waits_for_lock
      Timeout.timeout(5) do
        loop do
          blocked = ActiveRecord::Base.uncached do
            ActiveRecord::Base.connection.select_value(
              "SELECT cardinality(pg_blocking_pids(#{Integer(@worker_pid)})) > 0")
          end
          break if blocked
          assert @worker.alive?, "operation committed without waiting for the purchase lock"
          sleep 0.01
        end
      end
    end

    def worker_result
      Timeout.timeout(5) { @worker.value }
    end
end

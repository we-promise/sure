require "test_helper"
require "concurrent"

# Unsplitting while a transfer on one of the parts is confirmed or removed
# must end in a consistent state, and the unsplit must either succeed or be
# refused, never fail with a deadlock. The racing confirm or unlink may still
# fail when the unsplit removed its transfer first; that is Transfer's own
# behavior for a transfer deleted under it. Real threads on real connections,
# so this needs real commits.
class EntryUnsplitConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @family = Family.create!(name: "Unsplit Race", currency: "USD")
    @checking = Account.create!(
      family: @family, name: "Checking", currency: "USD",
      balance: 0, accountable: Depository.new)
    @loan = Account.create!(
      family: @family, name: "Mortgage", currency: "USD",
      balance: 0, accountable: Loan.new)
  end

  teardown do
    account_ids = [ @checking.id, @loan.id ]
    transaction_ids = Entry.where(account_id: account_ids, entryable_type: "Transaction").pluck(:entryable_id)
    Transfer.where(outflow_transaction_id: transaction_ids).or(Transfer.where(inflow_transaction_id: transaction_ids)).delete_all
    Entry.where(account_id: account_ids).where.not(parent_entry_id: nil).delete_all
    Entry.where(account_id: account_ids).delete_all
    Transaction.where(id: transaction_ids).delete_all
    @checking.destroy
    @loan.destroy
    @family.destroy
  end

  test "unsplitting while a part's transfer is confirmed keeps the split or removes the transfer" do
    5.times do
      parent, transfer = split_with_part_transfer(status: "pending")

      race(unsplit: -> { parent.unsplit_once! }, other: -> { transfer.confirm! })

      # Uncached: this thread's query cache still holds the rows read before the race.
      ActiveRecord::Base.uncached do
        if Entry.find(parent.id).split_parent?
          assert Transfer.find(transfer.id).confirmed?, "a split that stays must keep its confirmed transfer"
        else
          assert_not Transfer.exists?(transfer.id), "an unsplit must not leave the transfer behind"
        end
      end
    end
  end

  test "unsplitting while a part's transfer is removed keeps the split or removes the transfer" do
    5.times do
      parent, transfer = split_with_part_transfer(status: "pending")
      # Confirming gives the legs transfer kinds, so removing the transfer
      # updates them before it deletes the transfer row.
      transfer.confirm!

      race(unsplit: -> { parent.unsplit_once! }, other: -> { transfer.destroy! })

      ActiveRecord::Base.uncached do
        if Transfer.exists?(transfer.id)
          assert Transfer.find(transfer.id).confirmed?
          assert Entry.find(parent.id).split_parent?, "a split must not be removed while its transfer stays"
        end
      end
    end
  end

  private
    def split_with_part_transfer(status:)
      parent = Entry.create!(
        account: @checking, name: "Mortgage payment", date: Date.current,
        amount: 100, currency: "USD", entryable: Transaction.new)
      part = parent.split!([ { name: "Principal", amount: 60 }, { name: "Interest", amount: 40 } ]).first
      loan_entry = Entry.create!(
        account: @loan, name: "Payment", date: Date.current,
        amount: -60, currency: "USD", entryable: Transaction.new)
      transfer = Transfer.create!(inflow_transaction: loan_entry.transaction, outflow_transaction: part.transaction, status: status, amount: 60)

      [ Entry.find(parent.id), Transfer.find(transfer.id) ]
    end

    # Starts both actions at the same moment. The unsplit may only succeed or
    # be refused.
    def race(unsplit:, other:)
      errors = Concurrent::Array.new
      latch = Concurrent::CountDownLatch.new(2)

      threads = [ [ unsplit, true ], [ other, false ] ].map do |action, collect|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            latch.count_down
            latch.wait(5)
            action.call
          rescue Entry::SplitPartTransferredError
            nil
          rescue => e
            errors << e if collect
          end
        end
      end
      threads.each(&:join)

      assert_empty errors.map { |e| "#{e.class}: #{e.message}" }
    end
end

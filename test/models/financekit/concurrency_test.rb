require "test_helper"
require "concurrent"
require_relative "../../support/financekit_test_helper"

class Financekit::ConcurrencyTest < ActiveSupport::TestCase
  include FinancekitTestHelper
  self.use_transactional_tests = false

  setup do
    family = Family.create!(name: "FinanceKit race", currency: "USD")
    user = family.users.create!(email: "financekit-#{SecureRandom.hex(8)}@example.test", password: "test-password", role: "admin")
    financekit_setup(user: user)
  end

  teardown do
    @family&.destroy!
  end

  test "simultaneous duplicate uploads commit one inbox identity" do
    envelope = financekit_envelope
    ids = race(2) { FinancekitBatch.accept!(FinancekitItem.find(@item.id), envelope).id }
    assert_equal 1, ids.uniq.size
    assert_equal 1, @item.financekit_batches.count
  end

  test "concurrent workers apply canonical data and receipt once" do
    batch = FinancekitBatch.accept!(@item, financekit_envelope)
    results = race(2) { Financekit::Processor.new(FinancekitItem.find(@item.id)).apply_next! }
    assert_equal [ false, true ], results.sort_by { |value| value ? 1 : 0 }
    assert_equal "applied", batch.reload.status
    assert_equal 1, @source.account.entries.count
    assert_equal 1, @item.syncs.count
  end

  test "disconnect racing a worker leaves no unapplied import after revocation" do
    batch = FinancekitBatch.accept!(@item, financekit_envelope)
    race(2) do |index|
      item = FinancekitItem.find(@item.id)
      index.zero? ? item.disconnect! : Financekit::Processor.new(item).apply_next!
    end
    assert_equal "revoked", @item.reload.status
    assert_includes %w[applied revoked], batch.reload.status
    assert_equal batch.status == "applied" ? 1 : 0, @source.account.entries.count
    assert_not Financekit::Processor.new(@item).apply_next!
  end

  private
    def race(count)
      latch = Concurrent::CountDownLatch.new(count)
      threads = count.times.map do |index|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            latch.count_down
            raise "Concurrency barrier timed out" unless latch.wait(5)
            yield index
          end
        end
      end
      threads.map(&:value)
    ensure
      threads&.each(&:join)
    end
end

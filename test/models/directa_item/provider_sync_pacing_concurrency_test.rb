require "test_helper"

class DirectaItem::ProviderSyncPacingConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "a second database session cannot enter the same item provider lock" do
    item = DirectaItem.new(id: SecureRandom.uuid)
    pool = ActiveRecord::Base.connection_pool
    assert_operator pool.size, :>=, 2
    outer_pid = nil
    thread_pid = nil

    result = pool.with_connection do |connection|
      outer_pid = connection.select_value("SELECT pg_backend_pid()")
      item.with_provider_sync_lock do
        Thread.new do
          pool.with_connection do |thread_connection|
            thread_pid = thread_connection.select_value("SELECT pg_backend_pid()")
            item.with_provider_sync_lock { :entered }
          end
        end.value
      end
    end

    assert_not_equal outer_pid, thread_pid
    assert_equal false, result
  end
end

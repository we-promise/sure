require "test_helper"

class IdentifyRecurringTransactionsJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @token = SecureRandom.uuid
  end

  test "skips identification while a Coinbase provider sync is in flight" do
    coinbase_item = @family.coinbase_items.create!(
      name: "Coinbase Pro",
      api_key: "test-api-key-#{SecureRandom.hex(4)}",
      api_secret: "test-api-secret-#{SecureRandom.hex(8)}"
    )
    Sync.create!(syncable: coinbase_item, status: :syncing)

    RecurringTransaction::Identifier.any_instance.expects(:identify_recurring_patterns).never

    IdentifyRecurringTransactionsJob.new.perform(@family.id, @token)
  end

  test "skips identification while a Mercury provider sync is in flight" do
    mercury_item = mercury_items(:one)
    Sync.create!(syncable: mercury_item, status: :pending)

    RecurringTransaction::Identifier.any_instance.expects(:identify_recurring_patterns).never

    IdentifyRecurringTransactionsJob.new.perform(@family.id, @token)
  end

  test "runs identification when no provider syncs are in flight" do
    # Sanity: there are no incomplete syncs in the fixture set by default.
    Sync.for_family(@family).incomplete.find_each(&:destroy)

    RecurringTransaction::Identifier.any_instance.expects(:identify_recurring_patterns).once

    IdentifyRecurringTransactionsJob.new.perform(@family.id, @token)
  end

  test "skips when family is missing" do
    RecurringTransaction::Identifier.any_instance.expects(:identify_recurring_patterns).never

    IdentifyRecurringTransactionsJob.new.perform(SecureRandom.uuid, @token)
  end

  test "skips when a newer scheduled run supersedes this one" do
    # Rails.cache is NullStore in the test env (writes are no-ops), so we stub
    # the read directly to simulate a newer token landing in the cache
    # between this job being enqueued and being picked up.
    cache_key = IdentifyRecurringTransactionsJob.debounce_key(@family.id)
    Rails.cache.stubs(:read).with(cache_key).returns(SecureRandom.uuid)

    RecurringTransaction::Identifier.any_instance.expects(:identify_recurring_patterns).never

    assert_nil IdentifyRecurringTransactionsJob.new.perform(@family.id, @token)
  end

  test "runs when the cache still holds its own token" do
    Sync.for_family(@family).incomplete.find_each(&:destroy)
    cache_key = IdentifyRecurringTransactionsJob.debounce_key(@family.id)
    Rails.cache.stubs(:read).with(cache_key).returns(@token)

    RecurringTransaction::Identifier.any_instance.expects(:identify_recurring_patterns).once

    IdentifyRecurringTransactionsJob.new.perform(@family.id, @token)
  end
end

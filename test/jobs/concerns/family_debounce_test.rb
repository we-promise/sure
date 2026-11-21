require "test_helper"

class FamilyDebounceTest < ActiveJob::TestCase
  class DebouncedJob < ApplicationJob
    include FamilyDebounce
    self.debounce_key_prefix = "family_debounce_test"

    def perform(family_id, token); end

    def run?(family_id, token)
      !superseded?(family_id, token)
    end
  end

  setup do
    @family_id = SecureRandom.uuid
    # The test env uses :null_store, which would hide the debounce entirely.
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
  end

  test "only the newest scheduled token runs" do
    first = schedule
    second = schedule

    assert_not DebouncedJob.new.run?(@family_id, first)
    assert DebouncedJob.new.run?(@family_id, second)
  end

  test "a cache write that lands out of order leaves exactly one run" do
    first = schedule
    second = schedule
    # The earlier schedule's write arrives last.
    Rails.cache.write(DebouncedJob.debounce_key(@family_id), first)

    assert DebouncedJob.new.run?(@family_id, first)
    assert_not DebouncedJob.new.run?(@family_id, second)
  end

  test "tokens are scoped to the family" do
    token = schedule
    schedule(SecureRandom.uuid)

    assert DebouncedJob.new.run?(@family_id, token)
  end

  test "a missing key lets the run proceed" do
    assert DebouncedJob.new.run?(@family_id, SecureRandom.uuid)
  end

  test "a failed enqueue keeps the already queued run" do
    queued = schedule
    DebouncedJob.any_instance.stubs(:successfully_enqueued?).returns(false)

    fallback_called = false
    DebouncedJob.enqueue_debounced(@family_id, wait: 1.second, expires_in: 1.minute) { fallback_called = true }

    assert fallback_called
    assert DebouncedJob.new.run?(@family_id, queued)
  end

  test "a rolled-back schedule keeps the already queued run" do
    queued = schedule

    ActiveRecord::Base.transaction(requires_new: true) do
      DebouncedJob.enqueue_debounced(@family_id, wait: 1.second, expires_in: 1.minute)
      raise ActiveRecord::Rollback
    end

    assert DebouncedJob.new.run?(@family_id, queued)
  end

  private
    def schedule(family_id = @family_id)
      DebouncedJob.enqueue_debounced(family_id, wait: 1.second, expires_in: 1.minute) { flunk "enqueue failed" }
      enqueued_jobs.last[:args].last
    end
end

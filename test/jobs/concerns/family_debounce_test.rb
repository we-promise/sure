require "test_helper"

class FamilyDebounceTest < ActiveSupport::TestCase
  class DebouncedJob < ApplicationJob
    include FamilyDebounce
    self.debounce_key_prefix = "family_debounce_test"

    def run?(family_id, token)
      !superseded?(family_id, token)
    end
  end

  setup do
    @family_id = SecureRandom.uuid
    # The test env uses :null_store, which would hide the debounce entirely.
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
  end

  test "only the newest claimed token runs" do
    first = DebouncedJob.claim_debounce_token(@family_id, expires_in: 1.minute)
    second = DebouncedJob.claim_debounce_token(@family_id, expires_in: 1.minute)

    assert_not DebouncedJob.new.run?(@family_id, first)
    assert DebouncedJob.new.run?(@family_id, second)
  end

  test "a cache write that lands out of order leaves exactly one run" do
    first = DebouncedJob.claim_debounce_token(@family_id, expires_in: 1.minute)
    second = DebouncedJob.claim_debounce_token(@family_id, expires_in: 1.minute)
    # The earlier schedule's write arrives last.
    Rails.cache.write(DebouncedJob.debounce_key(@family_id), first)

    assert DebouncedJob.new.run?(@family_id, first)
    assert_not DebouncedJob.new.run?(@family_id, second)
  end

  test "tokens are scoped to the family" do
    token = DebouncedJob.claim_debounce_token(@family_id, expires_in: 1.minute)
    DebouncedJob.claim_debounce_token(SecureRandom.uuid, expires_in: 1.minute)

    assert DebouncedJob.new.run?(@family_id, token)
  end

  test "a missing key lets the run proceed" do
    assert DebouncedJob.new.run?(@family_id, SecureRandom.uuid)
  end
end

require "test_helper"

class DebugLogEntryTest < ActiveSupport::TestCase
  test "capture infers provider key and family from account" do
    entry = DebugLogEntry.capture(
      category: "provider_sync",
      level: "warn",
      message: "Provider event",
      source: "Provider::Test",
      account: accounts(:depository),
      provider: :twelve_data,
      metadata: { test: true }
    )

    assert entry.persisted?
    assert_equal "twelve_data", entry.provider_key
    assert_equal accounts(:depository), entry.account
    assert_equal accounts(:depository).family, entry.family
  end
end

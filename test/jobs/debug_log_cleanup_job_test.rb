require "test_helper"

class DebugLogCleanupJobTest < ActiveJob::TestCase
  test "deletes entries older than 90 days" do
    old_entry = DebugLogEntry.create!(
      category: "old_event",
      level: "info",
      message: "old",
      source: "Test",
      created_at: 91.days.ago,
      updated_at: 91.days.ago
    )
    recent_entry = DebugLogEntry.create!(
      category: "recent_event",
      level: "info",
      message: "recent",
      source: "Test"
    )

    assert_difference "DebugLogEntry.count", -1 do
      DebugLogCleanupJob.perform_now
    end

    assert_not DebugLogEntry.exists?(old_entry.id)
    assert DebugLogEntry.exists?(recent_entry.id)
  end
end

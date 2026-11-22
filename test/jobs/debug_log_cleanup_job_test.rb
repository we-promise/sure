require "test_helper"

class DebugLogCleanupJobTest < ActiveJob::TestCase
  setup do
    @original_retention_days = Rails.application.config.x.debug_log.retention_days
    Rails.application.config.x.debug_log.retention_days = 90
  end

  teardown do
    Rails.application.config.x.debug_log.retention_days = @original_retention_days
  end

  test "deletes entries older than 90 days" do
    travel_to Time.zone.parse("2026-05-17 12:00:00") do
      old_entry = DebugLogEntry.create!(
        category: "old_event",
        level: "info",
        message: "old",
        source: "Test",
        created_at: 91.days.ago,
        updated_at: 91.days.ago
      )
      boundary_entry = DebugLogEntry.create!(
        category: "boundary_event",
        level: "info",
        message: "boundary",
        source: "Test",
        created_at: 90.days.ago,
        updated_at: 90.days.ago
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
      assert DebugLogEntry.exists?(boundary_entry.id)
      assert DebugLogEntry.exists?(recent_entry.id)
    end
  end

  test "uses configured retention days" do
    Rails.application.config.x.debug_log.retention_days = 30

    travel_to Time.zone.parse("2026-05-17 12:00:00") do
      old_entry = DebugLogEntry.create!(
        category: "old_event",
        level: "info",
        message: "old",
        source: "Test",
        created_at: 31.days.ago,
        updated_at: 31.days.ago
      )
      boundary_entry = DebugLogEntry.create!(
        category: "boundary_event",
        level: "info",
        message: "boundary",
        source: "Test",
        created_at: 30.days.ago,
        updated_at: 30.days.ago
      )

      assert_difference "DebugLogEntry.count", -1 do
        DebugLogCleanupJob.perform_now
      end

      assert_not DebugLogEntry.exists?(old_entry.id)
      assert DebugLogEntry.exists?(boundary_entry.id)
    end
  end
end

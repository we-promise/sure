require "test_helper"

class SimplefinItemsHelperTest < ActionView::TestCase
  test "#activity_when returns nil for blank time" do
    assert_nil activity_when(nil)
    assert_nil activity_when("")
  end

  test "#activity_when returns 'today' for current time" do
    assert_equal "today", activity_when(Time.current)
  end

  test "#activity_when returns 'today' for earlier today" do
    # Freeze at mid-day so 6.hours.ago is guaranteed to fall on the same
    # calendar day regardless of when the suite runs.
    travel_to(Time.zone.parse("2026-04-17 15:00:00")) do
      assert_equal "today", activity_when(6.hours.ago)
    end
  end

  test "#activity_when returns 'yesterday' one day back" do
    assert_equal "yesterday", activity_when(1.day.ago)
  end

  test "#activity_when returns 'N days ago' for older dates" do
    # Freeze time so relative "N days ago" stays stable regardless of the
    # hour-of-day the suite runs.
    travel_to(Time.zone.parse("2026-04-17 15:00:00")) do
      assert_equal "5 days ago", activity_when(5.days.ago)
      # 2 days ago is the first value that hits the plural "N days ago" branch
      # (0 -> today, 1 -> yesterday, >=2 -> N days ago).
      assert_equal "2 days ago", activity_when(2.days.ago)
    end
  end

  test "#activity_when respects injected now: for deterministic formatting" do
    now = Time.zone.parse("2026-04-17 12:00:00")
    assert_equal "7 days ago", activity_when(now - 7.days, now: now)
  end

  # ---- simplefin_error_tooltip (pre-existing) ----
  test "#simplefin_error_tooltip returns nil for blank stats" do
    assert_nil simplefin_error_tooltip(nil)
    assert_nil simplefin_error_tooltip({})
    assert_nil simplefin_error_tooltip({ "total_errors" => 0 })
  end

  test "#simplefin_error_tooltip builds a sample with bucket counts" do
    stats = {
      "total_errors" => 3,
      "errors" => [
        { "name" => "Chase", "message" => "Timeout" },
        { "name" => "Citi", "message" => "Auth" }
      ],
      "error_buckets" => { "auth" => 1, "network" => 2 }
    }
    tooltip = simplefin_error_tooltip(stats)
    assert_includes tooltip, "Errors:"
    assert_includes tooltip, "3"
    assert_includes tooltip, "auth: 1"
  end
end

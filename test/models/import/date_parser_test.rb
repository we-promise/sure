require "test_helper"

class Import::DateParserTest < ActiveSupport::TestCase
  test "detects a complete ISO timestamp without discarding its time" do
    result = Import::DateParser.detect([ "2026-09-17T14:48:50Z" ])

    assert_equal :detected, result.status
    assert_equal "iso8601", result.format
    parsed = Import::DateParser.parse("2026-09-17T14:48:50Z", format: result.format)
    assert_equal Date.new(2026, 9, 17), parsed.date
    assert_equal Time.utc(2026, 9, 17, 14, 48, 50), parsed.timestamp
  end

  test "requires a choice for ambiguous dates and two digit years" do
    result = Import::DateParser.detect([ "03/04/2026", "05/06/2026" ])
    assert_equal :ambiguous, result.status
    assert_nil result.format
    assert_includes result.formats, "%m/%d/%Y"
    assert_includes result.formats, "%d/%m/%Y"
    assert_equal :ambiguous, Import::DateParser.detect([ "17/09/26" ]).status
  end

  test "checks beyond fifty distinct values and treats equivalent day directives as one format" do
    dates = 60.times.map { |n| "03/04/#{2000 + n}" } + [ "17/04/2026" ]
    result = Import::DateParser.detect(dates)

    assert_equal :detected, result.status
    assert_equal "%d/%m/%Y", result.format
  end

  test "does not guess from the majority when any row is invalid or incompatible" do
    [ [], [ "" ], [ "17/09/2026", "09/18/2026" ], [ "2026-09-17", "bad" ] ].each do |samples|
      assert_equal :unsupported, Import::DateParser.detect(samples).status
    end
  end

  test "strict parsing rejects trailing data, invalid dates and incomplete years" do
    [ "2026-09-17T14:48:50Z", "2026-09-17garbage", "2026-02-30", "26-09-17" ].each do |value|
      assert_raises(ArgumentError) { Import::DateParser.parse(value, format: "%Y-%m-%d") }
    end
  end

  test "timestamp parsing preserves offset, source date and microseconds" do
    parsed = Import::DateParser.parse("2026-09-18T01:30:00.123456+02:00", format: "iso8601")

    assert_equal Date.new(2026, 9, 18), parsed.date
    assert_equal "2026-09-17T23:30:00.123456Z", parsed.timestamp.utc.iso8601(6)
    assert_nil Import::DateParser.parse("2026-09-17", format: "%Y-%m-%d").timestamp
  end

  test "minute-only offset timestamps detect and retain their source date" do
    [ "2026-09-18T01:30Z", "2026-09-18T01:30+02:00" ].each do |value|
      assert_equal "iso8601", Import::DateParser.detect([ value ]).format
      parsed = Import::DateParser.parse(value, format: "iso8601")
      assert_equal Date.new(2026, 9, 18), parsed.date
      assert_equal 0, parsed.timestamp.sec
      assert_equal(value.end_with?("Z") ? 0 : 7200, parsed.timestamp.utc_offset)
    end

    assert_equal Time.utc(2026, 9, 17, 23, 30), Import::DateParser.parse("2026-09-18T01:30+02:00", format: "iso8601").timestamp
  end

  test "timestamps require an explicit offset and a valid clock and calendar" do
    %w[2026-09-17T14:48:50 2026-02-30T10:00:00Z 2026-09-17T25:00:00Z 2026-09-17T14:60:00Z 2026-09-17T14:00:61Z].each do |value|
      assert_raises(ArgumentError) { Import::DateParser.parse(value, format: "iso8601") }
    end
  end

  test "legacy callers retain their fallback and best-match contract" do
    assert_equal "%Y-%m-%d", Import.detect_date_format([])
    assert_equal "%m/%d/%Y", Import.detect_date_format([ "3/29/2026", "invalid" ])
  end
end

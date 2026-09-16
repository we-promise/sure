require "minitest/autorun"
require_relative "../../../../app/models/provider"
require_relative "../../../../app/models/provider/account_data"
require_relative "../../../../app/models/provider/account_data/migration_value"

class Provider::AccountData::MigrationValueTest < Minitest::Test
  Value = Provider::AccountData::MigrationValue

  def test_round_trips_source_types_without_json_coercion
    source = {
      "decimal" => BigDecimal("1234567890123456.123456789012345678"),
      "zero" => BigDecimal("0"), "null" => nil, "false" => false, "empty" => [],
      "date" => Date.new(2025, 4, 9),
      "time" => Time.iso8601("2025-04-09T03:02:01.123456789+02:00"),
      "datetime" => DateTime.iso8601("2025-04-09T03:02:01.123456789+02:00"),
      :symbol_key => { "symbol" => :unchanged }, "unicode" => "銀行 / café"
    }

    assert_equal source, Value.load(Value.dump(source))
    assert_instance_of BigDecimal, Value.load(Value.dump(source)).fetch("decimal")
    assert_instance_of DateTime, Value.load(Value.dump(source)).fetch("datetime")
  end

  def test_hash_order_does_not_change_checksums_and_tag_shaped_payloads_stay_data
    left = { "b" => [ "decimal", "pretend type" ], "a" => { "type" => "date", "value" => false } }
    right = { "a" => { "value" => false, "type" => "date" }, "b" => [ "decimal", "pretend type" ] }

    assert_equal Value.dump(left), Value.dump(right)
    assert_equal left, Value.load(Value.dump(left))
  end

  def test_rejects_nonfinite_and_ambiguous_values
    [ Float::INFINITY, Float::NAN, BigDecimal("NaN"), Object.new ].each do |value|
      assert_raises(ArgumentError) { Value.dump(value) }
    end
    assert_raises(ArgumentError) { Value.decode([ "unknown", 1 ]) }
    assert_raises(ArgumentError) { Value.decode([ "scalar", [] ]) }
    assert_raises(ArgumentError) do
      Value.decode([ "hash", [ [ [ "scalar", "same" ], [ "scalar", 1 ] ], [ [ "scalar", "same" ], [ "scalar", 2 ] ] ] ])
    end
  end
end

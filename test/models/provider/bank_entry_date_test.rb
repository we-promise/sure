# frozen_string_literal: true

require "test_helper"

class Provider::BankEntryDateTest < ActiveSupport::TestCase
  test "prefers first non-future candidate in order" do
    as_of = Date.new(2026, 8, 5)
    selected = Provider::BankEntryDate.select(
      [
        [ "booking_date", Date.new(2026, 8, 7) ],
        [ "value_date", Date.new(2026, 8, 4) ],
        [ "transaction_date", Date.new(2026, 8, 3) ]
      ],
      as_of: as_of
    )

    assert_equal Date.new(2026, 8, 4), selected
  end

  test "keeps preferred date when it is not in the future" do
    as_of = Date.new(2026, 8, 5)
    selected = Provider::BankEntryDate.select(
      [
        [ "booking_date", Date.new(2026, 8, 5) ],
        [ "value_date", Date.new(2026, 8, 1) ]
      ],
      as_of: as_of
    )

    assert_equal Date.new(2026, 8, 5), selected
  end

  test "clamps to as_of when every candidate is in the future" do
    as_of = Date.new(2026, 8, 5)
    selected = Provider::BankEntryDate.select(
      [
        [ "booking_date", Date.new(2026, 8, 9) ],
        [ "value_date", Date.new(2026, 8, 8) ]
      ],
      as_of: as_of
    )

    assert_equal as_of, selected
  end

  test "returns nil when no date candidates are present" do
    assert_nil Provider::BankEntryDate.select([ [ "booking_date", nil ], [ "value_date", nil ] ])
  end

  test "provenance stores compact string values" do
    provenance = Provider::BankEntryDate.provenance(
      [
        [ :booking_date, Date.new(2026, 8, 7) ],
        [ :value_date, "2026-08-04" ],
        [ :transaction_date, nil ],
        [ :posted_at, "" ]
      ]
    )

    assert_equal(
      { "booking_date" => "2026-08-07", "value_date" => "2026-08-04" },
      provenance
    )
  end

  test "family_today uses family timezone near UTC midnight" do
    family = OpenStruct.new(timezone: "America/Los_Angeles")

    travel_to Time.utc(2026, 8, 5, 2, 0, 0) do
      assert_equal Date.new(2026, 8, 5), Time.now.utc.to_date
      assert_equal Date.new(2026, 8, 4), Provider::BankEntryDate.family_today(family)
    end
  end
end

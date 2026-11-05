require "test_helper"

class LanguagesHelperTest < ActionView::TestCase
  test "timezone options have unique values so the saved zone stays selected" do
    values = timezone_options.map(&:last)

    assert_equal values.uniq, values
  end

  test "timezone options list renamed zones only under their current name" do
    values = timezone_options.map(&:last)

    LanguagesHelper::RENAMED_TIMEZONES.each do |old_name, new_name|
      assert_includes values, new_name
      assert_not_includes values, old_name
    end
  end

  test "timezone options list each IANA zone with its identifier" do
    moscow = timezone_options.select { |_, value| value == "Europe/Moscow" }

    assert_equal [ [ "(+03:00) Europe/Moscow", "Europe/Moscow" ] ], moscow
    assert_includes timezone_options.map(&:last), "America/Argentina/Cordoba"
  end

  test "timezone options cover every zone offered by Rails" do
    rails_identifiers = ActiveSupport::TimeZone.all.map { |tz| tz.tzinfo.identifier }
    renamed = rails_identifiers.map { |identifier| LanguagesHelper::RENAMED_TIMEZONES.fetch(identifier, identifier) }

    assert_empty renamed - timezone_options.map(&:last)
  end

  test "timezone options are sorted by offset and use readable labels" do
    offsets = timezone_options.map { |_, value| ActiveSupport::TimeZone[value].utc_offset }

    assert_equal offsets.sort, offsets
    assert_includes timezone_options, [ "(-05:00) America/New York", "America/New_York" ]
  end

  test "timezone options show a saved old spelling in place of its renamed zone" do
    base = timezone_options
    # Hosts without tzdata's legacy names cannot resolve "Europe/Kiev".
    ActiveSupport::TimeZone.stubs(:[]).with("Europe/Kiev").returns(stub(utc_offset: 2.hours.to_i))

    options = timezone_options("Europe/Kiev")

    assert_includes options, [ "(+02:00) Europe/Kiev", "Europe/Kiev" ]
    assert_not_includes options.map(&:last), "Europe/Kyiv"
    assert_equal base.size, options.size
  end

  test "timezone options add any other saved zone outside the list" do
    base = timezone_options
    ActiveSupport::TimeZone.stubs(:[]).with("US/Eastern").returns(stub(utc_offset: -5.hours.to_i))

    options = timezone_options("US/Eastern")

    assert_includes options, [ "(-05:00) US/Eastern", "US/Eastern" ]
    assert_equal base.size + 1, options.size
  end

  test "timezone options ignore an unknown saved zone" do
    assert_equal timezone_options, timezone_options("Not/AZone")
  end
end

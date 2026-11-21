require "test_helper"

class LanguagesHelperTest < ActionView::TestCase
  # The zone list is cached per process with the offsets current when it was
  # built. Another test may have built it under travel_to, when some zones had
  # a different standard offset, so rebuild it at the real time.
  setup do
    LanguagesHelper.instance_variable_set(:@timezone_option_rows, nil)
  end

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

  test "timezone labels show the standard offset during daylight saving time too" do
    travel_to Time.utc(2024, 7, 1, 12) do
      LanguagesHelper.instance_variable_set(:@timezone_option_rows, nil)

      assert_includes timezone_options, [ "(-05:00) America/New York", "America/New_York" ]
      assert_includes timezone_options, [ "(+01:00) Europe/Berlin", "Europe/Berlin" ]
    end
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

  test "folded_translations case-folds every supported locale's translation of a key" do
    folded = LanguagesHelper.folded_translations("models.category.defaults.food_and_drink")

    assert_includes folded, "food & drink"
    assert_includes folded, "restaurants & bars"
    assert folded.frozen?
  end

  test "folded_translations skips locales without a translation" do
    assert_empty LanguagesHelper.folded_translations("languages_helper_test.missing_key")
  end

  test "folded_translations is rebuilt once the current request is reset" do
    key = "languages_helper_test.stored_key"
    I18n.backend.store_translations(:en, languages_helper_test: { stored_key: "First" })
    assert_equal Set.new([ "first" ]), LanguagesHelper.folded_translations(key)

    I18n.backend.store_translations(:en, languages_helper_test: { stored_key: "Second" })
    assert_equal Set.new([ "first" ]), LanguagesHelper.folded_translations(key)

    Current.reset
    assert_equal Set.new([ "second" ]), LanguagesHelper.folded_translations(key)
  ensure
    I18n.reload!
  end
end

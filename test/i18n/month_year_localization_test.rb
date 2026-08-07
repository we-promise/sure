require "test_helper"

class MonthYearLocalizationTest < ActiveSupport::TestCase
  TARGETS = {
    "app/views/budget_categories/show.html.erb" => 1,
    "app/views/reports/_budget_performance.html.erb" => 1,
    "app/views/reports/print.html.erb" => 2
  }.freeze

  test "new month and year labels use an explicit localized format" do
    TARGETS.each do |relative_path, expected_count|
      source = Rails.root.join(relative_path).read

      assert_equal expected_count, source.scan('format: "%B %Y"').size, relative_path
      refute_includes source, "format: :month_year", relative_path
    end
  end

  test "explicit month and year format follows the active locale" do
    date = Date.new(2026, 3, 1)

    assert_equal "März 2026", I18n.with_locale(:de) { I18n.l(date, format: "%B %Y") }
    assert_equal "March 2026", I18n.with_locale(:en) { I18n.l(date, format: "%B %Y") }
  end
end

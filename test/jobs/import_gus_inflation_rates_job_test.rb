require "test_helper"

class ImportGusInflationRatesJobTest < ActiveJob::TestCase
  test "does not import when global toggle is disabled" do
    Setting.gus_inflation_import_enabled = false

    GusInflationRate.expects(:import_range!).never

    ImportGusInflationRatesJob.perform_now(start_year: 2023, end_year: 2024)
  ensure
    Setting.gus_inflation_import_enabled = false
  end

  test "imports and stores status when enabled" do
    Setting.gus_inflation_import_enabled = true

    GusInflationRate.expects(:import_range!).with(start_year: 2023, end_year: 2024, force: true).returns(24)

    ImportGusInflationRatesJob.perform_now(start_year: 2023, end_year: 2024, force: true)

    assert_equal 24, Setting.gus_inflation_last_import_count
    assert_equal "2023-2024", Setting.gus_inflation_last_import_range
    assert Setting.gus_inflation_last_import_at.present?
    assert_nil Setting.gus_inflation_last_import_error
  ensure
    Setting.gus_inflation_import_enabled = false
  end
end

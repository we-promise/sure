require "test_helper"

class ImportInflationRatesJobTest < ActiveJob::TestCase
  test "does not run importer when global toggle is disabled" do
    old_val = Setting.gus_inflation_import_enabled
    Setting.gus_inflation_import_enabled = false

    InflationRateImporter.expects(:new).never

    ImportInflationRatesJob.perform_now(start_year: 2023, end_year: 2024)
  ensure
    Setting.gus_inflation_import_enabled = old_val
  end

  test "runs importer when forced even if global toggle is disabled" do
    old_val = Setting.gus_inflation_import_enabled
    Setting.gus_inflation_import_enabled = false

    importer = mock
    InflationRateImporter.expects(:new).with(start_year: 2023, end_year: 2024, force: true, providers: [ "gus_sdp" ]).returns(importer)
    importer.expects(:import_all).returns({ "gus_sdp" => 12 })

    ImportInflationRatesJob.perform_now(start_year: 2023, end_year: 2024, force: true, providers: [ "gus_sdp" ])

    assert_equal 12, Setting.gus_inflation_last_import_count
  ensure
    Setting.gus_inflation_import_enabled = old_val
  end

  test "imports and stores summary status when enabled" do
    old_val = Setting.gus_inflation_import_enabled
    Setting.gus_inflation_import_enabled = true

    importer = mock
    InflationRateImporter.expects(:new).with(start_year: 2023, end_year: 2024, force: true, providers: [ "gus_sdp", "us_bls" ]).returns(importer)
    importer.expects(:import_all).returns({ "gus_sdp" => 12, "us_bls" => 10 })

    ImportInflationRatesJob.perform_now(start_year: 2023, end_year: 2024, force: true, providers: [ "gus_sdp", "us_bls" ])

    assert_equal 22, Setting.gus_inflation_last_import_count
    assert_equal "2023-2024", Setting.gus_inflation_last_import_range
    assert Setting.gus_inflation_last_import_at.present?
    assert_nil Setting.gus_inflation_last_import_error
  ensure
    Setting.gus_inflation_import_enabled = old_val
  end

  test "stores error and re-raises when importer fails" do
    old_val = Setting.gus_inflation_import_enabled
    Setting.gus_inflation_import_enabled = true

    importer = mock
    InflationRateImporter.expects(:new).returns(importer)
    importer.expects(:import_all).raises(StandardError.new("boom"))

    assert_raises(StandardError) do
      ImportInflationRatesJob.perform_now(start_year: 2023, end_year: 2024)
    end

    assert_equal "boom", Setting.gus_inflation_last_import_error
  ensure
    Setting.gus_inflation_import_enabled = old_val
  end
end

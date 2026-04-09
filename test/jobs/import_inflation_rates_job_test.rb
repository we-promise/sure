require "test_helper"
require "json"

class ImportInflationRatesJobTest < ActiveJob::TestCase
  test "does not run importer when global toggle is disabled" do
    Setting.stubs(:inflation_import_enabled_effective).returns(false)

    InflationRateImporter.expects(:new).never

    ImportInflationRatesJob.perform_now(start_year: 2023, end_year: 2024)
  end

  test "runs importer when forced even if global toggle is disabled" do
    Setting.stubs(:inflation_import_enabled_effective).returns(false)

    importer = mock
    InflationRateImporter.expects(:new).with(start_year: 2023, end_year: 2024, force: true, providers: [ "gus_sdp" ]).returns(importer)
    importer.expects(:import_all).returns({ "gus_sdp" => 12 })

    ImportInflationRatesJob.perform_now(start_year: 2023, end_year: 2024, force: true, providers: [ "gus_sdp" ])

    assert_equal 12, Setting.inflation_last_import_count
  end

  test "runs provider-scoped import even when global toggle is disabled" do
    Setting.stubs(:inflation_import_enabled_effective).returns(false)

    importer = mock
    InflationRateImporter.expects(:new).with(start_year: 2023, end_year: 2024, force: false, providers: [ "us_bls" ]).returns(importer)
    importer.expects(:import_all).returns({ "us_bls" => 10 })

    ImportInflationRatesJob.perform_now(start_year: 2023, end_year: 2024, providers: [ "us_bls" ])

    assert_equal 10, Setting.inflation_last_import_count
  end

  test "imports and stores summary status when enabled" do
    Setting.stubs(:inflation_import_enabled_effective).returns(true)

    importer = mock
    InflationRateImporter.expects(:new).with(start_year: 2023, end_year: 2024, force: false, providers: [ "gus_sdp", "us_bls" ]).returns(importer)
    importer.expects(:import_all).returns({ "gus_sdp" => 12, "us_bls" => 10 })

    ImportInflationRatesJob.perform_now(start_year: 2023, end_year: 2024, providers: [ "gus_sdp", "us_bls" ])

    assert_equal 22, Setting.inflation_last_import_count
    assert_equal "2023-2024", Setting.inflation_last_import_range
    assert Setting.inflation_last_import_at.present?
    assert_nil Setting.inflation_last_import_error
    assert_kind_of String, Setting.inflation_last_import_details
    assert_equal({ "gus_sdp" => 12, "us_bls" => 10 }, JSON.parse(Setting.inflation_last_import_details))
  end

  test "stores error and re-raises when importer fails" do
    Setting.stubs(:inflation_import_enabled_effective).returns(true)

    importer = mock
    InflationRateImporter.expects(:new).returns(importer)
    importer.expects(:import_all).raises(StandardError.new("boom"))

    assert_raises(StandardError) do
      ImportInflationRatesJob.perform_now(start_year: 2023, end_year: 2024)
    end

    assert_equal "boom", Setting.inflation_last_import_error
  end
end

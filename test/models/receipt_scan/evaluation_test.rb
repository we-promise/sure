require "test_helper"

class ReceiptScan::EvaluationTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @dir = Pathname(Dir.mktmpdir("receipt_eval"))
    write_pair("a", merchant: "Corner Grocer", date: "2026-11-14", total: "50.00", currency: "USD")
    write_pair("b", merchant: "Biedronka", date: "2026-11-10", total: "12.99", currency: "PLN", nip: "5260250274")
  end

  teardown do
    FileUtils.rm_rf(@dir)
  end

  test "scores each field against the expected values" do
    extractions = {
      "a" => build_receipt_extraction(merchant: "CORNER GROCER LTD", date: Date.new(2026, 11, 14), total: BigDecimal("50.00"), currency: "USD"),
      "b" => build_receipt_extraction(merchant: "Lidl", date: Date.new(2026, 11, 11), total: BigDecimal("12.99"), currency: "PLN",
                                      nip: "5260250274", line_items: [])
    }
    provider = stub(supports_receipt_extraction?: true)
    provider.stubs(:extract_receipt).returns(*%w[a b].map { Provider::Response.new(success?: true, data: extractions[_1], error: nil) })

    report = ReceiptScan::Evaluation.new(dir: @dir, family: @family, provider:).run

    assert_equal 2, report["count"]
    assert_equal({ "merchant" => 0.5, "date" => 0.5, "total" => 1.0, "currency" => 1.0, "nip" => 1.0 }, report["accuracy"])
    assert_equal %w[a b], report["results"].map { _1["name"] }
    assert report["flag_rate"].between?(0, 1)
    assert report["mean_latency_seconds"] >= 0
    assert_equal report, JSON.parse(File.read(@dir.join("report.json")))
  end

  test "a receipt named report stops the run before its expected values are overwritten" do
    write_pair("report", merchant: "Corner Grocer", date: "2026-11-14", total: "50.00", currency: "USD")
    expected = @dir.join("report.json").read
    provider = stub(supports_receipt_extraction?: true)
    provider.expects(:extract_receipt).never

    assert_raises(ArgumentError) { ReceiptScan::Evaluation.new(dir: @dir, family: @family, provider:).run }
    assert_equal expected, @dir.join("report.json").read
  end

  test "counts a failed extraction as wrong on every field" do
    provider = stub(supports_receipt_extraction?: true)
    provider.stubs(:extract_receipt).returns(Provider::Response.new(success?: false, data: nil, error: Provider::Error.new("boom")))

    report = ReceiptScan::Evaluation.new(dir: @dir, family: @family, provider:).run

    assert_equal 0.0, report["accuracy"]["total"]
    assert_equal "boom", report["results"].first["error"]
  end

  test "a failed extraction counts against the nip it was expected to read" do
    provider = stub(supports_receipt_extraction?: true)
    provider.stubs(:extract_receipt).returns(
      Provider::Response.new(success?: true, data: build_receipt_extraction(currency: "USD"), error: nil),
      Provider::Response.new(success?: false, data: nil, error: Provider::Error.new("boom"))
    )
    write_pair("a", merchant: "Corner Grocer", date: "2026-11-14", total: "50.00", currency: "USD", nip: "5260250274")
    FileUtils.rm(@dir.join("b.jpg"))
    write_pair("c", total: "12.99", currency: "PLN", nip: "5260250274")

    report = ReceiptScan::Evaluation.new(dir: @dir, family: @family, provider:).run

    assert_equal 0.0, report["accuracy"]["nip"]
    assert_equal false, report["results"].last["scores"]["nip"]
  end

  private
    def write_pair(name, **expected)
      FileUtils.cp(file_fixture("receipts/rotated.jpg"), @dir.join("#{name}.jpg"))
      File.write(@dir.join("#{name}.json"), expected.to_json)
    end
end

require "test_helper"

class ReceiptScan::EvaluationTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    use_ai_routes
    @dir = Pathname(Dir.mktmpdir("receipt_eval"))
    write_pair("a", merchant: "Corner Grocer", date: "2026-11-14", total: "50.00", currency: "USD")
    write_pair("b", merchant: "Biedronka", date: "2026-11-10", total: "12.99", currency: "PLN", nip: "5260250274")
  end

  teardown do
    FileUtils.rm_rf(@dir)
  end

  test "scores each field against the expected values" do
    answers = [
      receipt_ai_answer(merchant: "CORNER GROCER LTD", date: "2026-11-14", total: 50.0, currency: "USD"),
      receipt_ai_answer(merchant: "Lidl", date: "2026-11-11", total: 12.99, currency: "PLN", nip: "5260250274", line_items: [])
    ]
    stub_ai(:extract_receipt) { answers.shift }

    report = evaluate

    assert_equal 2, report["count"]
    assert_equal({ "merchant" => 0.5, "date" => 0.5, "total" => 1.0, "currency" => 1.0, "nip" => 1.0 }, report["accuracy"])
    assert_equal %w[a b], report["results"].map { _1["name"] }
    assert report["flag_rate"].between?(0, 1)
    assert report["mean_latency_seconds"] >= 0
    assert_equal report, JSON.parse(File.read(@dir.join("report.json")))
  end

  test "an expected total written with a decimal comma is compared as a number" do
    write_pair("a", total: "50,00", currency: "USD")
    FileUtils.rm(@dir.join("b.jpg"))
    stub_ai(:extract_receipt, returns: receipt_ai_answer(total: 50.0))

    assert_equal 1.0, evaluate["accuracy"]["total"]
  end

  test "a receipt named report stops the run before its expected values are overwritten" do
    write_pair("report", merchant: "Corner Grocer", date: "2026-11-14", total: "50.00", currency: "USD")
    expected = @dir.join("report.json").read
    requests = stub_ai(:extract_receipt, returns: receipt_ai_answer)

    assert_raises(ArgumentError) { evaluate }
    assert_equal expected, @dir.join("report.json").read
    assert_empty requests
  end

  test "counts a failed extraction as wrong on every field" do
    stub_ai(:extract_receipt, raises: Ai::Error::InvalidOutput.new("boom"))

    report = evaluate

    assert_equal 0.0, report["accuracy"]["total"]
    assert_match "boom", report["results"].first["error"]
  end

  test "a file that isn't a receipt is counted as wrong rather than stopping the run" do
    File.write(@dir.join("c.png"), "not an image")
    File.write(@dir.join("c.json"), { total: "1.00" }.to_json)
    stub_ai(:extract_receipt, returns: receipt_ai_answer)

    report = evaluate

    assert_equal 3, report["count"]
    assert_equal({ "total" => false }, report["results"].last["scores"])
  end

  test "a failed extraction counts against the nip it was expected to read" do
    answers = [ receipt_ai_answer(currency: "USD") ]
    stub_ai(:extract_receipt) { answers.shift || raise(Ai::Error::InvalidOutput, "boom") }
    write_pair("a", merchant: "Corner Grocer", date: "2026-11-14", total: "50.00", currency: "USD", nip: "5260250274")
    FileUtils.rm(@dir.join("b.jpg"))
    write_pair("c", total: "12.99", currency: "PLN", nip: "5260250274")

    report = evaluate

    assert_equal 0.0, report["accuracy"]["nip"]
    assert_equal false, report["results"].last["scores"]["nip"]
  end

  test "stops when no routed model reads images" do
    use_ai_routes(extract_receipt: %w[gpu/qwen3-8b])

    assert_raises(ArgumentError) { evaluate }
  end

  private
    def evaluate = ReceiptScan::Evaluation.new(dir: @dir, family: @family, user: @user).run

    def write_pair(name, **expected)
      FileUtils.cp(file_fixture("receipts/rotated.jpg"), @dir.join("#{name}.jpg"))
      File.write(@dir.join("#{name}.json"), expected.to_json)
    end
end

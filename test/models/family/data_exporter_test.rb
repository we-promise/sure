require "test_helper"

class Family::DataExporterTest < ActiveSupport::TestCase
  setup do
    @exporter = Family::DataExporter.new(families(:dylan_family))
  end

  # ── CSV injection prevention (CWE-1236) ──────────────────────────────────────

  test "sanitize_csv prefixes formula-starting values with single quote" do
    dangerous = {
      "=SUM(A1)"    => "'=SUM(A1)",
      "+cmd"        => "'+cmd",
      "-1+1"        => "'-1+1",
      "@user"       => "'@user",
      "\tcell"     => "'\tcell",
      "\nrow"      => "'\nrow"
    }
    dangerous.each do |input, expected|
      assert_equal expected, @exporter.send(:sanitize_csv, input), "Failed for: #{input}"
    end
  end

  test "sanitize_csv leaves safe strings unchanged" do
    %w[hello Normal 123 category].each do |safe|
      assert_equal safe, @exporter.send(:sanitize_csv, safe)
    end
  end

  test "sanitize_csv passes through non-string values unchanged" do
    assert_nil @exporter.send(:sanitize_csv, nil)
    assert_equal 42, @exporter.send(:sanitize_csv, 42)
  end
end

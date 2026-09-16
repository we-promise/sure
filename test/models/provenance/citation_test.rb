require "test_helper"

class Provenance::CitationTest < ActiveSupport::TestCase
  test "parses a plain citation with a reliability grade" do
    citation = Provenance::Citation.parse!("Private bank statement 2026-03-31, category subtotals (grade: A)")

    assert_equal "Private bank statement 2026-03-31, category subtotals", citation.text
    assert_equal "A", citation.grade
    assert_not citation.estimated?
    assert_not citation.proxy?
  end

  test "parses an estimated citation" do
    citation = Provenance::Citation.parse!("estimated: linear interpolation over 2024-08 / 2024-12 anchors (grade: C)")

    assert citation.estimated?
    assert citation.proxy?
    assert_equal "C", citation.grade
    assert_equal "linear interpolation over 2024-08 / 2024-12 anchors", citation.text
  end

  test "grade is optional on a non-estimated citation" do
    citation = Provenance::Citation.parse!("Appraisal report 2026-03-12")

    assert_nil citation.grade
    assert_not citation.estimated?
  end

  # The suffix pre-check and the FORMAT pattern must agree on spacing, or a
  # citation whose grade the pre-check accepts gets parsed as ungraded and the
  # caller's reliability is silently dropped.
  test "accepts a grade suffix whatever the spacing after the colon" do
    [ "Doc (grade:A)", "Doc (grade: A)", "Doc (grade:  A)" ].each do |raw|
      citation = Provenance::Citation.parse!(raw)

      assert_equal "A", citation.grade, "expected #{raw.inspect} to parse as grade A"
      assert_equal "Doc", citation.text
    end
  end

  test "rejects an unknown grade regardless of spacing" do
    [ "Doc (grade:D)", "Doc (grade:  D)" ].each do |raw|
      assert_raises(Provenance::Citation::InvalidError, "expected #{raw.inspect} to be rejected") do
        Provenance::Citation.parse!(raw)
      end
    end
  end

  test "rejects a blank citation" do
    assert_raises(Provenance::Citation::InvalidError) { Provenance::Citation.parse!("   ") }
    assert_raises(Provenance::Citation::InvalidError) { Provenance::Citation.parse!(nil) }
  end

  test "rejects an unknown reliability grade" do
    error = assert_raises(Provenance::Citation::InvalidError) do
      Provenance::Citation.parse!("Some document (grade: D)")
    end

    assert_match(/grade must be one of/, error.message)
  end

  test "rejects an estimate that carries no grade" do
    error = assert_raises(Provenance::Citation::InvalidError) do
      Provenance::Citation.parse!("estimated: interpolated from neighbouring months")
    end

    assert_match(/reliability grade/, error.message)
  end

  test "rejects an estimated marker that does not use the exact prefix" do
    error = assert_raises(Provenance::Citation::InvalidError) do
      Provenance::Citation.parse!("Estimated: interpolated (grade: C)")
    end

    assert_match(/exact prefix/, error.message)
  end

  test "rejects a citation with no document named" do
    assert_raises(Provenance::Citation::InvalidError) { Provenance::Citation.parse!("ab") }
  end

  test "rejects an over-long citation" do
    assert_raises(Provenance::Citation::InvalidError) do
      Provenance::Citation.parse!("x" * (Provenance::Citation::MAX_LENGTH + 1))
    end
  end

  test "valid? does not raise" do
    assert Provenance::Citation.valid?("Statement 2026-01-31 (grade: A)")
    assert_not Provenance::Citation.valid?("")
  end
end

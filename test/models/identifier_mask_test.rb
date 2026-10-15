require "test_helper"

class IdentifierMaskTest < ActiveSupport::TestCase
  test "keeps only the last 4 characters behind the marker" do
    assert_equal "•••7890", IdentifierMask.last4("DE89370400440532017890")
    assert_equal "•••2345", IdentifierMask.last4(12345)
  end

  test "returns nil for blank input" do
    assert_nil IdentifierMask.last4(nil)
    assert_nil IdentifierMask.last4("")
    assert_nil IdentifierMask.last4("   ", strip_whitespace: true)
  end

  # Fine for an account number, but the reason this must never mask secrets.
  test "shows a value of 4 characters or fewer in full" do
    assert_equal "•••123", IdentifierMask.last4("123")
    assert_equal "•••1234", IdentifierMask.last4("1234")
  end

  test "hide_short returns nil for values under 4 characters" do
    assert_nil IdentifierMask.last4("123", hide_short: true)
    assert_equal "•••1234", IdentifierMask.last4("1234", hide_short: true)
  end

  test "strip_whitespace ignores grouping spaces" do
    assert_equal "•••7890", IdentifierMask.last4("DE89 3704 0044 0532 0178 90", strip_whitespace: true)
    assert_equal "•••8 90", IdentifierMask.last4("DE89 3704 0044 0532 0178 90")
  end

  test "accepts a custom prefix" do
    assert_equal "****1234", IdentifierMask.last4("55551234", prefix: "****")
  end

  test "last4_chars returns the characters without a marker" do
    assert_equal "1234", IdentifierMask.last4_chars("5555 1234", strip_whitespace: true)
    assert_nil IdentifierMask.last4_chars("12", hide_short: true)
  end
end

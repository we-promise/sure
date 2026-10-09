require "test_helper"

class Rule::SafeRegexTest < ActiveSupport::TestCase
  test "an ordinary pattern is accepted" do
    assert_nil Rule::SafeRegex.error_for('^amzn\s+mktp')
    assert_nil Rule::SafeRegex.error_for("(coffee|tea) shop$")
  end

  test "a nested-quantifier pattern is accepted because Postgres runs it in linear time" do
    assert_nil Rule::SafeRegex.error_for("(a+)+$")

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    matched = ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([ "SELECT ? ~* ?", "#{'a' * 30_000}b", "(a+)+$" ])
    )
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal false, matched
    assert_operator elapsed, :<, 1.0
  end

  test "blank and whitespace-only patterns are refused" do
    assert_equal :blank, Rule::SafeRegex.error_for(nil)
    assert_equal :blank, Rule::SafeRegex.error_for("   ")
  end

  test "length is capped at the boundary" do
    assert_nil Rule::SafeRegex.error_for("a" * Rule::SafeRegex::MAX_LENGTH)
    assert_equal :too_long, Rule::SafeRegex.error_for("a" * (Rule::SafeRegex::MAX_LENGTH + 1))
  end

  test "back-references are refused" do
    assert_equal :backreference, Rule::SafeRegex.error_for('(a*)*\1c')
    assert_equal :backreference, Rule::SafeRegex.error_for('(x)(y)\2')
  end

  test "an escaped backslash followed by a digit is not a back-reference" do
    assert_nil Rule::SafeRegex.error_for('a\\\\1')
  end

  test "a pattern Postgres rejects is refused at save time, not at run time" do
    assert_equal :invalid, Rule::SafeRegex.error_for("(")
    assert_equal :invalid, Rule::SafeRegex.error_for("[a-")
  end

  # The database driver refuses a string with a NUL in it outright (ArgumentError),
  # so the probe would raise out of validation instead of reporting a bad pattern.
  test "a pattern containing a null byte is invalid and never reaches the database" do
    ActiveRecord::Base.connection.expects(:select_value).never

    assert_equal :invalid, Rule::SafeRegex.error_for("ab\u0000c")
    assert_equal :invalid, Rule::SafeRegex.error_for("\u0000")
  end

  test "a pattern Postgres calls too complex is refused" do
    assert_equal :invalid, Rule::SafeRegex.error_for("^(a{1,255}){1,255}(b)")
  end

  test "a database error that is not a regex error is not reported as an invalid pattern" do
    ActiveRecord::Base.connection.stubs(:select_value).raises(ActiveRecord::StatementInvalid.new("connection lost"))

    assert_raises(ActiveRecord::StatementInvalid) { Rule::SafeRegex.error_for("abc") }
  end

  test "a failed probe inside an open transaction does not poison it" do
    ActiveRecord::Base.transaction do
      assert_equal :invalid, Rule::SafeRegex.error_for("(")
      assert_equal 1, ActiveRecord::Base.connection.select_value("SELECT 1")
    end
  end

  test "with_timeout raises TimeoutError when the statement outlives the limit" do
    assert_raises(Rule::SafeRegex::TimeoutError) do
      Rule::SafeRegex.with_timeout(20) { ActiveRecord::Base.connection.execute("SELECT pg_sleep(1)") }
    end
  end

  test "with_timeout leaves the limit off once the block returns" do
    Rule::SafeRegex.with_timeout(20) { ActiveRecord::Base.connection.execute("SELECT 1") }

    assert_nothing_raised { ActiveRecord::Base.connection.execute("SELECT pg_sleep(0.05)") }
  end
end

# Guards the `matches_regex` rule operator.
#
# The pattern runs inside Postgres (`~*`), not in Ruby, so the rules are
# Postgres' own (Advanced Regular Expressions). Its matcher is not a
# backtracking engine: nested quantifiers such as `(a+)+$` stay linear. Two
# things are not safe, and this class closes both:
#
# * back-references (`\1`..`\9`), which are exponential in Postgres' engine,
#   are refused outright;
# * patterns Postgres will not compile (`parentheses () not balanced`,
#   `regular expression is too complex`) only fail when a query runs them, which
#   would put a saved, active rule into a failing state on every sync. They are
#   probed once, at save. A pattern containing a null byte is refused without a
#   probe, because the database driver will not send one.
#
# Execution is bounded as well: #with_timeout runs a block under a Postgres
# `statement_timeout` and raises TimeoutError, so a rule cannot hold a worker or
# a request open.
class Rule::SafeRegex
  MAX_LENGTH = 200
  PROBE_TIMEOUT_MS = 1_000
  EXECUTION_TIMEOUT_MS = 5_000

  TimeoutError = Class.new(StandardError)

  # An escape is a backslash and the character after it. Reading them in pairs
  # keeps an escaped backslash followed by a digit (`\\1`) from reading as a
  # back-reference.
  ESCAPE_PAIR = /\\./m

  # @param pattern [String, nil] the pattern a user wrote
  # @return [Symbol, nil] nil when safe, otherwise one of :blank, :too_long,
  #   :backreference, :invalid, :too_complex
  def self.error_for(pattern)
    new(pattern).error
  end

  # Runs the block with Postgres' statement_timeout set for its duration only.
  #
  # SET LOCAL lasts until the end of the outermost transaction, and a rule's
  # validation runs inside the save's transaction. Releasing a savepoint does
  # not undo it, so the previous limit is put back explicitly; a failure rolls
  # the savepoint back, which undoes it.
  #
  # @param milliseconds [Integer]
  # @raise [TimeoutError] when the database cancels the statement
  def self.with_timeout(milliseconds = EXECUTION_TIMEOUT_MS)
    connection = ActiveRecord::Base.connection
    connection.transaction(requires_new: true) do
      previous = connection.select_value("SHOW statement_timeout")
      connection.execute(set_timeout_sql(Integer(milliseconds)))
      result = yield
      connection.execute(set_timeout_sql(previous))
      result
    end
  rescue ActiveRecord::QueryCanceled
    raise TimeoutError, "regular expression exceeded #{milliseconds} ms"
  end

  # SET takes no bind parameters, so the value is quoted into the statement.
  def self.set_timeout_sql(value)
    ActiveRecord::Base.sanitize_sql_array([ "SET LOCAL statement_timeout = ?", value ])
  end
  private_class_method :set_timeout_sql

  def initialize(pattern)
    @pattern = pattern.to_s
  end

  def error
    # The database driver refuses a string containing NUL before Postgres sees it,
    # so the probe could not judge it. Checked first: String#strip removes NUL, so
    # "\0" alone would otherwise read as blank.
    return :invalid if pattern.include?("\0")
    return :blank if pattern.strip.empty?
    return :too_long if pattern.length > MAX_LENGTH
    return :backreference if backreference?

    compile_error
  end

  private
    attr_reader :pattern

    def backreference?
      pattern.scan(ESCAPE_PAIR).any? { |escape| escape.match?(/\A\\[1-9]\z/) }
    end

    # Postgres compiles the pattern before it looks at the subject, so an empty
    # subject is enough to surface a pattern it rejects.
    def compile_error
      self.class.with_timeout(PROBE_TIMEOUT_MS) do
        ActiveRecord::Base.connection.select_value(
          ActiveRecord::Base.sanitize_sql_array([ "SELECT '' ~* ?", pattern ])
        )
      end
      nil
    rescue TimeoutError
      :too_complex
    rescue ActiveRecord::StatementInvalid => e
      # Only Postgres' own verdict on the pattern (SQLSTATE 2201B) is a bad pattern;
      # a lost connection or an aborted transaction is not the user's mistake.
      raise unless e.cause.is_a?(PG::InvalidRegularExpression)

      :invalid
    end
end

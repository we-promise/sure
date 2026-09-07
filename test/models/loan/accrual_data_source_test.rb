require "test_helper"

# #10 (risk R17): "Accrual reads `balances` directly and **never**
# `Balance::ChartSeriesBuilder`, whose interval is period-dependent."
#
# The hazard is specific: `Balance::ChartSeriesBuilder` picks its interval from
# the requested period (daily for short windows, weekly or monthly for long
# ones), so a 30-year schedule built through it would silently accrue interest
# on interpolated points rather than on the end-of-day balances the lender
# charges on. The bug would not raise; it would produce plausible, wrong money.
#
# This is a source-level guard rather than a behavioural assertion, and it is
# worth being honest about the difference: it proves the calculation files do
# not *name* the chart builder, not that every balance they read is an
# end-of-day balance. It catches the realistic regression -- someone reaching
# for the convenient existing series builder while adding a feature -- at the
# moment it is introduced, which a behavioural test written after the fact
# would not.
class Loan::AccrualDataSourceTest < ActiveSupport::TestCase
  CALCULATION_FILES = %w[
    app/models/loan/interest_accrual.rb
    app/models/loan/simulator.rb
    app/models/loan/amortization_schedule.rb
    app/models/loan/amortization_math.rb
    app/models/loan/offset_resolver.rb
    app/models/loan/payoff_projection.rb
    app/models/loan/rate_resolver.rb
  ].freeze

  test "the loan calculation path never reaches for the period-dependent chart series builder" do
    CALCULATION_FILES.each do |relative_path|
      path = Rails.root.join(relative_path)
      assert path.file?, "#{relative_path} does not exist; update CALCULATION_FILES if it moved"

      assert_no_match(/ChartSeriesBuilder/, path.read,
        "#{relative_path} references Balance::ChartSeriesBuilder, whose interval depends on the " \
        "requested period -- accrual must read end-of-day balances directly (#10, risk R17)")
    end
  end

  test "the offset resolver reads balances rather than a charted series" do
    # Executable code only. Matching the raw file would let this guard pass on
    # the word "balances" in a comment -- and this file's own header comment
    # contains it -- so deleting the actual balance read would leave the guard
    # green. Ripper drops comments and string contents, leaving the tokens that
    # actually run.
    source = executable_source("app/models/loan/offset_resolver.rb")

    assert_match(/\.balances\b/, source,
      "the offset resolver must read the account's `balances` association directly; without " \
      "that read this guard is pointing at the wrong file (#10, risk R17)")
    assert_match(/\bend_balance\b/, source,
      "the offset resolver must read `end_balance` -- the end-of-day figure R17 is about, as " \
      "opposed to a period-dependent charted series")
  end

  private

    # Source with comments and string literals removed, so a guard cannot be
    # satisfied by prose that merely mentions the thing it is checking for.
    def executable_source(relative_path)
      require "ripper"

      Ripper.lex(Rails.root.join(relative_path).read)
        .reject { |(_pos, type, _tok, _state)| %i[on_comment on_embdoc on_embdoc_beg on_embdoc_end on_tstring_content].include?(type) }
        .map { |(_pos, _type, tok, _state)| tok }
        .join
    end
end

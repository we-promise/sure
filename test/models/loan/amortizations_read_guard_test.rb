require "test_helper"

# `loan.amortizations` is a CACHE, valid only while `schedule_current?`.
#
# Since #39 no read path rebuilds it, so any surface reading it directly is
# reading a cache it has not checked. Four separate surfaces made that mistake
# before this guard existed -- the schedule table (#39), the payoff projection
# (#35 x #39), the Overview payoff-date card (#7) and the payoff chart (#52) --
# each producing the same silent failure: two different loans' numbers on one
# screen, with no exception and no failing test (risk R21).
#
# `Loan::AmortizationSchedule#display_rows` hides the distinction: persisted
# rows when they are current, recomputed in memory when they are not. This test
# makes reaching past it a build failure rather than a review catch (#56).
class Loan::AmortizationsReadGuardTest < ActiveSupport::TestCase
  # Each entry needs a reason. A path without one is not an exception, it is an
  # oversight waiting to be inherited.
  PERMITTED = {
    "app/models/loan.rb" =>
      "Owns the cache: rebuild/delete write paths, and the schedule_current? " \
      "freshness checks that decide whether it may be trusted.",
    "app/models/loan/amortization_schedule.rb" =>
      "#display_rows is the sanctioned reader -- the one place allowed to " \
      "decide between persisted and recomputed rows.",
    "app/controllers/api/v1/loans_controller.rb" =>
      "Reads persisted rows deliberately AND reports their freshness to the " \
      "caller via `status` (current/stale/missing), so the consumer is never " \
      "misled about what it received.",
    "app/views/api/v1/loans/amortization_schedule.json.jbuilder" =>
      "Renders the response above, whose `status` field carries the same " \
      "freshness declaration."
  }.freeze

  test "no new surface reads persisted amortizations without declaring their freshness" do
    offenders = Dir.glob(Rails.root.join("app/**/*.{rb,erb,jbuilder}")).filter_map do |path|
      relative = Pathname.new(path).relative_path_from(Rails.root).to_s
      next if relative == "app/models/loan_amortization.rb"
      next if PERMITTED.key?(relative)
      next unless strip_comments(File.read(path)).match?(/\bamortizations\b/)

      relative
    end

    assert_empty offenders, <<~MESSAGE
      These read `loan.amortizations` directly:

        #{offenders.join("\n  ")}

      That association is a cache, valid only while `schedule_current?`, and no
      read path rebuilds it since #39. Read `Loan::AmortizationSchedule#display_rows`
      instead -- persisted rows when current, recomputed when not.

      If a surface genuinely must read persisted rows, it has to DECLARE their
      freshness the way the API does, and be added to PERMITTED with a reason.
    MESSAGE
  end

  test "every permitted path exists and still reads the association" do
    PERMITTED.each do |relative, reason|
      full = Rails.root.join(relative)
      assert full.file?, "PERMITTED lists #{relative}, which no longer exists -- prune it"
      assert_match(/\bamortizations\b/, strip_comments(full.read),
        "PERMITTED lists #{relative}, which no longer reads the association -- prune it")
      assert reason.present?, "#{relative} needs a reason"
    end
  end

  # File-level permission is too coarse for loan.rb: it legitimately owns the
  # cache AND has historically carried display code (#payoff_chart_payload was
  # the fourth surface to get this wrong). So loan.rb is checked method by
  # method -- only the methods that own or verify the cache may name it.
  LOAN_RB_METHODS = %w[
    rebuild_amortization_schedule
    rebuild_amortization_schedule_locked!
    ensure_amortization_schedule_current!
    schedule_current?
    schedule_current_for_signature?
    reset_amortizations_association!
  ].freeze

  test "only cache-owning methods in loan.rb name the association" do
    offenders = methods_in("app/models/loan.rb").filter_map do |name, body|
      next if LOAN_RB_METHODS.include?(name)
      next unless strip_comments(body).match?(/\bamortizations\b/)

      name
    end

    assert_empty offenders, <<~MESSAGE
      These methods in app/models/loan.rb read the persisted association:

        #{offenders.join("\n  ")}

      loan.rb is permitted to name `amortizations` only where it owns or
      verifies the cache. A method that computes a figure for display must read
      `amortization_schedule.display_rows` -- #payoff_chart_payload was the
      fourth surface to get this wrong (#56).
    MESSAGE
  end

  private

    # Comments do not count: a file may name the association to explain why it
    # deliberately does not use it -- `_overview.html.erb` does exactly that.
    # Splits a class body into method name => body. Relies on this file's
    # consistent `def`/matching-indent `end` style, which rubocop enforces.
    def methods_in(relative)
      lines = Rails.root.join(relative).read.lines
      methods = {}
      current = nil
      indent = nil
      lines.each do |line|
        if (match = line.match(/^(\s*)def ([a-zA-Z_][\w?!]*)/))
          indent = match[1]
          current = match[2]
          methods[current] = +""
        elsif current && line.rstrip == "#{indent}end"
          current = nil
        elsif current
          methods[current] << line
        end
      end
      methods
    end

    def strip_comments(source)
      source
        .gsub(/<%#.*?%>/m, "")
        .lines
        .reject { |line| line.strip.start_with?("#") }
        .join
    end
end

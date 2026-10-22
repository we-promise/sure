# The milestones on the way to financial independence: the years
# the portfolio reaches a quarter, a half, three quarters and all of the FI
# number, and Coast FI.
#
# Pure, like RetirementPlan::Simulation: it reads the simulation's rows and is
# handed everything else, and nothing here reads the clock, the database or
# the current request.
#
# Everything is compared in today's money: the FI number is today's spending
# over the withdrawal rate, so each year's `end_value_real` is set against it
# rather than the nominal value.
#
# Coast FI is the first year from which the portfolio, with no further saving,
# would grow at the real return to the FI number by the retirement year:
#
#   end_value_real(t) >= FI / (1 + real)^(retirement_year - t - 1)
#
# where real = (1 + r) / (1 + i) - 1. A year's end value has the years after it,
# up to the one before retirement, left to grow.
class RetirementPlan::Milestones
  FRACTIONS = { "fi_25" => BigDecimal("0.25"), "fi_50" => BigDecimal("0.5"), "fi_75" => BigDecimal("0.75"), "fi_100" => BigDecimal("1") }.freeze

  # `year` is nil when the milestone was already passed or is never reached
  # within the plan; `reached_already` tells the two apart.
  #
  # The four FI milestones are always present. Coast FI is left out entirely,
  # not given a nil year, when there is no retirement year or it is already
  # past: there is no saving year to coast from. A caller must read a missing
  # `coast` as "not applicable", never as reached.
  Milestone = Data.define(:key, :year, :age, :reached_already)

  def initialize(rows:, current_assets:, fi_number:, expected_annual_return:, inflation_rate:, retirement_year:, first_year:, birth_year:, path_retirement_year: nil)
    @rows = rows
    @current_assets = current_assets.to_d
    @fi_number = fi_number&.to_d
    @real_growth = (1 + expected_annual_return.to_d) / (1 + inflation_rate.to_d)
    @retirement_year = retirement_year
    # The rows stop saving when their own path retires, which in FIRE mode can
    # be before the plan's date. The Coast target still runs to the plan's.
    @saving_until = [ retirement_year, path_retirement_year ].compact.min
    @first_year = first_year
    # Required: every milestone reached in a year carries the age it is
    # reached at. RetirementPlan#milestones only calls this for a plannable
    # plan, which has one.
    raise ArgumentError, "birth_year is required" if birth_year.nil?

    @birth_year = birth_year
  end

  def all
    return [] if @fi_number.nil? || !@fi_number.positive?

    FRACTIONS.map { |key, fraction| fi_milestone(key, @fi_number * fraction) } + [ coast ].compact
  end

  private
    def fi_milestone(key, amount)
      return milestone(key, nil, reached_already: true) if @current_assets >= amount

      row = @rows.detect { |r| r.end_value_real >= amount }
      milestone(key, row&.year, reached_already: false)
    end

    # Only the saving years count: from the retirement year, the plan's or the
    # path's if earlier, there is nothing left to coast on. A retirement year
    # already past leaves none at all.
    def coast
      return nil if @retirement_year.nil? || @retirement_year < @first_year
      return milestone("coast", nil, reached_already: true) if @current_assets >= coast_target(@first_year - 1)

      row = @rows.detect { |r| r.year < @saving_until && r.end_value_real >= coast_target(r.year) }
      milestone("coast", row&.year, reached_already: false)
    end

    # The value at the end of `year` that grows to the FI number by the start
    # of the retirement year. Today's assets are the end of the year before.
    def coast_target(year)
      @fi_number / (@real_growth**[ @retirement_year - year - 1, 0 ].max)
    end

    def milestone(key, year, reached_already:)
      Milestone.new(key: key, year: year, age: year && year - @birth_year, reached_already: reached_already)
    end
end

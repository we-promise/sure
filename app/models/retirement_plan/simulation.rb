# The retirement planner's year-by-year projection.
#
# Pure, like RetirementPlan::Projection: every input is handed in, the
# reference date among them, and nothing here reads the clock, the database or
# the current request.
#
# One row per calendar year, from the reference date's year to the year the
# plan's owner reaches the end age. Within a year the withdrawal comes out
# first and the contribution goes in last:
#
#   V(n + 1) = (V(n) - W(n)) * (1 + r) + C(n)
#
# Before retirement W holds only one-off amounts, which is RetirementPlan::Projection's recurrence
# whenever there are none. From the retirement year, W is spending less
# income, never below zero, and income beyond spending is reinvested as C.
#
# `expected_annual_return` is the compound annual return before inflation.
# Streams marked `indexed` grow with `inflation_rate` from the reference year,
# as does the contribution. `end_value_real` is the end value in the
# reference year's money.
class RetirementPlan::Simulation
  # A calendar-year span of spending or income. `start_year` nil runs from the
  # reference year; `end_year` nil runs to the end age. A one-off is paid once,
  # in its start year.
  Stream = Data.define(:kind, :annual_amount, :start_year, :end_year, :indexed) do
    def initialize(kind:, annual_amount:, start_year: nil, end_year: nil, indexed: true)
      super(kind: kind.to_s, annual_amount: annual_amount.to_d, start_year:, end_year:, indexed:)
    end

    def active_in?(year, first_year)
      if kind == "one_off"
        year == (start_year || first_year)
      else
        (start_year.nil? || year >= start_year) && (end_year.nil? || year <= end_year)
      end
    end
  end

  Row = Data.define(:year, :age, :start_value, :contribution, :withdrawal, :growth, :end_value, :end_value_real)

  attr_reader :as_of, :retirement_year, :birth_year, :end_age

  def initialize(as_of:, current_assets:, annual_contribution:, expected_annual_return:, inflation_rate:, streams:, retirement_year:, birth_year:, end_age:)
    @as_of = as_of.to_date
    @current_assets = current_assets.to_d
    @annual_contribution = annual_contribution.to_d
    @return_rate = expected_annual_return.to_d
    @inflation_rate = inflation_rate.to_d
    @streams = streams
    @retirement_year = retirement_year
    @birth_year = birth_year
    @end_age = end_age
  end

  def first_year
    as_of.year
  end

  def last_year
    birth_year + end_age
  end

  def rows
    @rows ||= build_rows
  end

  def survives?
    depletion_year.nil?
  end

  # The first year whose withdrawal the portfolio cannot meet.
  def depletion_year
    rows
    @depletion_year
  end

  def depletion_age
    depletion_year && depletion_year - birth_year
  end

  private
    def build_rows
      value = @current_assets
      @depletion_year = nil

      (first_year..last_year).map do |year|
        n = year - first_year
        contribution, withdrawal = flows_for(year, n)
        start_value = value

        if @depletion_year.nil? && withdrawal > value
          @depletion_year = year
        end

        after_withdrawal = [ value - withdrawal, 0 ].max
        growth = after_withdrawal * @return_rate
        value = after_withdrawal + growth + contribution

        Row.new(
          year: year, age: year - birth_year, start_value: start_value,
          contribution: contribution, withdrawal: withdrawal, growth: growth,
          end_value: value, end_value_real: value / inflation_factor(n + 1)
        )
      end
    end

    # Before retirement: the contribution goes in, and only one-offs come out.
    # From the retirement year: spending less income comes out, and income
    # beyond spending goes back in.
    def flows_for(year, n)
      one_offs = total(year, n, "one_off")

      if year < retirement_year
        [ @annual_contribution * inflation_factor(n), one_offs ]
      else
        net = total(year, n, "expense") - total(year, n, "income")
        [ [ -net, 0 ].max, [ net, 0 ].max + one_offs ]
      end
    end

    def total(year, n, kind)
      @streams
        .select { |stream| stream.kind == kind && stream.active_in?(year, first_year) }
        .sum(BigDecimal("0")) { |stream| stream.indexed ? stream.annual_amount * inflation_factor(n) : stream.annual_amount }
    end

    def inflation_factor(years)
      (1 + @inflation_rate)**years
    end
end

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
# The first year counts only the part of it left from the reference date,
# the date itself included: its growth compounds over that fraction of a year,
# and its contribution and recurring flows are that fraction of a year's. A
# one-off is a single payment and comes out whole. Without this, a plan read
# on 31 December would count a whole year that has a day left.
#
# Before retirement the contribution is what the user saves after today's
# spending, so the seeded streams (today's living costs and loan repayments)
# stay out of it, while streams the user adds move it: an expense comes off
# it, income adds to it, and what the contribution cannot cover comes out of
# the portfolio. From the retirement year, W is spending less income, never
# below zero, and income beyond spending is reinvested as C.
#
# `expected_annual_return` is the compound annual return before inflation.
# Amounts are in the money of a calendar year: the contribution in the
# reference year's, a stream in its `base_year`'s (the reference year when
# nil). Those marked `indexed` grow with `inflation_rate` from that year.
# `end_value_real` is the end value in money of the reference date.
class RetirementPlan::Simulation
  # A calendar-year span of spending or income. `start_year` nil runs from the
  # reference year; `end_year` nil runs to the end age. A one-off is paid once,
  # in its start year. `seeded` marks a stream seeded from today's spending
  # and loans, which the contribution already pays for until retirement.
  Stream = Data.define(:kind, :annual_amount, :start_year, :end_year, :indexed, :base_year, :seeded) do
    def initialize(kind:, annual_amount:, start_year: nil, end_year: nil, indexed: true, base_year: nil, seeded: false)
      super(kind: kind.to_s, annual_amount: annual_amount.to_d, start_year:, end_year:, indexed:, base_year:, seeded:)
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
    raise ArgumentError, "the end-age year #{last_year} is before the reference year #{first_year}" if last_year < first_year
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

  # Each year's [contribution, withdrawal], which do not depend on returns.
  # RetirementPlan::MonteCarlo replays them under varying returns.
  def yearly_flows
    @yearly_flows ||= (first_year..last_year).map { |year| flows_for(year, year - first_year) }
  end

  def inflation_rate
    @inflation_rate
  end

  def current_assets
    @current_assets
  end

  def return_rate
    @return_rate
  end

  # The part of the first year left from the reference date, that day
  # included: 1 from 1 January, 1/365 from 31 December.
  def first_year_fraction
    @first_year_fraction ||= BigDecimal((as_of.end_of_year - as_of).to_i + 1) / as_of.end_of_year.yday
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
        growth = after_withdrawal * (growth_factor(n) - 1)
        value = after_withdrawal + growth + contribution

        Row.new(
          year: year, age: year - birth_year, start_value: start_value,
          contribution: contribution, withdrawal: withdrawal, growth: growth,
          end_value: value, end_value_real: value / inflation_factor(years_elapsed(n))
        )
      end
    end

    # Before retirement: the contribution, less manual spending and plus
    # manual income, goes in; what it cannot cover comes out, with one-offs.
    # From the retirement year: spending less income comes out, and income
    # beyond spending goes back in.
    def flows_for(year, n)
      one_offs = total(year, "one_off")

      net = if year < retirement_year
        @annual_contribution * inflation_factor(n) * part_of_year(n) +
          total(year, "income", manual_only: true) - total(year, "expense", manual_only: true)
      else
        total(year, "income") - total(year, "expense")
      end

      [ [ net, 0 ].max, [ -net, 0 ].max + one_offs ]
    end

    # A one-off is paid whole; a recurring stream only for the part of the
    # first year left.
    def total(year, kind, manual_only: false)
      n = year - first_year
      share = kind == "one_off" ? 1 : part_of_year(n)

      @streams
        .select { |stream| stream.kind == kind && stream.active_in?(year, first_year) && !(manual_only && stream.seeded) }
        .sum(BigDecimal("0")) { |stream| amount_in(stream, year) * share }
    end

    def amount_in(stream, year)
      return stream.annual_amount unless stream.indexed

      stream.annual_amount * inflation_factor(year - (stream.base_year || first_year))
    end

    def part_of_year(n)
      n.zero? ? first_year_fraction : 1
    end

    # Years from the reference date to the end of row n.
    def years_elapsed(n)
      first_year_fraction + n
    end

    def growth_factor(n)
      n.zero? ? first_year_growth : 1 + @return_rate
    end

    # Whole years exactly; a fraction of a year (only ever f + n) through the
    # first year's inflation, computed once, as BigDecimal#power is costly and
    # the solver runs a simulation per candidate year.
    def inflation_factor(years)
      whole = years.floor
      factor = (1 + @inflation_rate)**whole
      years == whole ? factor : factor * first_year_inflation
    end

    def first_year_growth
      @first_year_growth ||= fractional_power(1 + @return_rate)
    end

    def first_year_inflation
      @first_year_inflation ||= fractional_power(1 + @inflation_rate)
    end

    # BigDecimal#** takes only whole exponents exactly; the first year's
    # fraction needs #power with a precision.
    def fractional_power(base)
      first_year_fraction == 1 ? base : base.power(first_year_fraction, 20)
    end
end

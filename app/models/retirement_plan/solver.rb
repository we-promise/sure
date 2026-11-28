# FIRE mode: the earliest year the plan's owner can retire and still have the
# money last to the end age, on expected returns.
#
# Every whole year from the reference year to the end-age year is tried in
# turn and the first that lasts is the answer. A scan rather than a search:
# with dated income and spending, lasting from one year does not guarantee
# lasting from every later one, so a bisection could step over the answer.
# The plan is at most a hundred-odd years long, so the scan is cheap.
#
# Pure, like RetirementPlan::Simulation, which it runs.
class RetirementPlan::Solver
  # `retirement_year` nil when no year lasts; `depletion_age` then says when
  # the money runs out retiring at the last possible year.
  Result = Data.define(:retirement_year, :retirement_age, :depletion_age)

  def initialize(**simulation_inputs)
    @inputs = simulation_inputs
  end

  def call
    last_try = nil

    (first_year..last_year).each do |year|
      last_try = simulation(year)
      return Result.new(retirement_year: year, retirement_age: year - birth_year, depletion_age: nil) if last_try.survives?
    end

    Result.new(retirement_year: nil, retirement_age: nil, depletion_age: last_try&.depletion_age)
  end

  private
    def simulation(retirement_year)
      RetirementPlan::Simulation.new(**@inputs, retirement_year: retirement_year)
    end

    def first_year
      @inputs.fetch(:as_of).year
    end

    def birth_year
      @inputs.fetch(:birth_year)
    end

    def last_year
      birth_year + @inputs.fetch(:end_age)
    end
end

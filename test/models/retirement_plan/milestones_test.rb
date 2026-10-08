require "test_helper"

# The milestones on the way to financial independence.
class RetirementPlan::MilestonesTest < ActiveSupport::TestCase
  AS_OF = Date.new(2026, 3, 15)

  # FI number 300,000; 100,000 today; 10,000 a year saved at 5%; retiring in
  # 2046. Every figure below is hand-computed.
  def milestones(inflation_rate: 0, fi_number: 300_000, retirement_year: 2046, **overrides)
    inputs = {
      as_of: AS_OF, current_assets: 100_000, annual_contribution: 10_000,
      expected_annual_return: BigDecimal("0.05"), inflation_rate: BigDecimal(inflation_rate.to_s),
      streams: [], birth_year: 1980, end_age: 90
    }.merge(overrides)
    simulation = RetirementPlan::Simulation.new(**inputs, retirement_year: retirement_year || 2046)

    RetirementPlan::Milestones.new(
      rows: simulation.rows, current_assets: inputs[:current_assets], fi_number: fi_number,
      expected_annual_return: inputs[:expected_annual_return], inflation_rate: inputs[:inflation_rate],
      retirement_year: retirement_year, first_year: AS_OF.year, birth_year: inputs[:birth_year]
    )
  end

  def find(list, key)
    list.find { |m| m.key == key }
  end

  test "a milestone the portfolio has already passed is reached, with no year" do
    list = milestones.all

    assert_equal [ true, nil ], find(list, "fi_25").then { |m| [ m.reached_already, m.year ] }
  end

  test "each other milestone lands in the first year whose value in today's money reaches it" do
    list = milestones.all

    # 164,651.88 in 2029, 243,236.63 in 2033, 313,101.81 in 2036.
    assert_equal [ 2029, 2033, 2036 ], %w[fi_50 fi_75 fi_100].map { |key| find(list, key).year }
    assert_equal 49, find(list, "fi_50").age
    assert_equal [ false ], %w[fi_50].map { |key| find(list, key).reached_already }
  end

  test "a milestone reached exactly on its threshold counts" do
    # 2029 ends at 164,651.875 exactly, so a 50% of 329,303.75 is met to the cent.
    assert_equal 2029, find(milestones(fi_number: BigDecimal("329303.75")).all, "fi_50").year
  end

  test "Coast FI is the first year the value would grow, without further saving, to the FI number by retirement" do
    # 2027 ends at 130,750.00, and 300,000 / 1.05^18 is 124,656.20.
    # 2026 ends at 115,000.00, short of 300,000 / 1.05^19 = 118,720.19.
    assert_equal 2027, find(milestones.all, "coast").year
  end

  test "milestones and Coast FI are measured in today's money, at the real return" do
    list = milestones(inflation_rate: "0.03").all

    # 160,559.01 in today's money at the end of 2030. Nominally 2029 already
    # clears 150,000, which is the mistake this pins.
    assert_equal 2030, find(list, "fi_50").year
    # 270,421.19 against 300,000 x (1.03 / 1.05)^7 = 262,214.52; 2037's
    # 255,746.50 falls short of 257,219.96. At the nominal rate it would be 2028.
    assert_equal 2038, find(list, "coast").year
  end

  test "Coast FI counts only the saving years, so a portfolio that only grows past the target after retiring never coasted" do
    # Retiring in 2030, the saving years end at 164,651.88 against a target of
    # 300,000 for 2029; the portfolio passes 300,000 only in the 2040s.
    m = find(milestones(retirement_year: 2030).all, "coast")

    assert_equal [ nil, false ], [ m.year, m.reached_already ]
  end

  # A traditional plan can keep a retirement date that has passed. There is no
  # saving year left to coast on, so there is no Coast FI to show, even with
  # assets above the FI number.
  test "a retirement year already past has no Coast FI" do
    list = milestones(retirement_year: 2025, current_assets: 400_000).all

    assert_nil find(list, "coast")
    assert_equal %w[fi_25 fi_50 fi_75 fi_100], list.map(&:key)
  end

  test "a retirement year that is this year still has Coast FI" do
    assert find(milestones(retirement_year: 2026, current_assets: 400_000).all, "coast")
  end

  test "a portfolio that could already coast is reached, with no year" do
    # 200,000 today against 300,000 / 1.05^20 = 113,066.84.
    m = find(milestones(current_assets: 200_000).all, "coast")

    assert_equal [ true, nil ], [ m.reached_already, m.year ]
  end

  test "a milestone the plan never reaches has no year and is not reached" do
    m = find(milestones(fi_number: 50_000_000).all, "fi_100")

    assert_equal [ nil, false ], [ m.year, m.reached_already ]
  end

  test "without a retirement year there is no Coast FI, and without an FI number there are no milestones" do
    assert_nil find(milestones(retirement_year: nil).all, "coast")
    assert_empty milestones(fi_number: nil).all
  end

  test "nothing in the milestones engine reads the clock, the database or the current request" do
    source = Rails.root.join("app/models/retirement_plan/milestones.rb").read

    assert_no_match(/Date\.(current|today)|Time\.(current|now|zone)|Current\.|ActiveRecord|\.where\(|\.find/, source)
  end
end

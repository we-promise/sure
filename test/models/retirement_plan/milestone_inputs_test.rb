require "test_helper"

# What a plan's milestones are built from.
class RetirementPlan::MilestoneInputsTest < ActiveSupport::TestCase
  AS_OF = Date.new(2026, 3, 15)

  setup do
    @family = families(:dylan_family)
    @member = users(:family_member)
    RetirementPlan.where(user: @member).delete_all
    AccountShare.where(user: @member).delete_all
    account = Account.create!(family: @family, owner: @member, accountable: Depository.new,
                              name: "Checking #{SecureRandom.hex(3)}", currency: "USD", balance: 80_000)
    Balance.create!(account: account, date: AS_OF, balance: 80_000, currency: "USD")
    # 1,000 a month of spending: an FI number of 300,000 at 4%.
    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("1000"))
    IncomeStatement.any_instance.stubs(:median_income).returns(BigDecimal("0"))
    @plan = RetirementPlan.create!(user: @member, birth_year: 1980, retirement_date: Date.new(2046, 1, 1),
                                   safe_withdrawal_rate: BigDecimal("0.04"))
  end

  def find(list, key)
    list.find { |m| m.key == key }
  end

  test "the milestones measure against the simple projection's FI number" do
    # 80,000 clears a quarter of 300,000 (75,000) but not of 400,000 (100,000).
    assert find(@plan.milestones(as_of: AS_OF), "fi_25").reached_already

    @plan.update!(safe_withdrawal_rate: BigDecimal("0.03"))
    assert_not find(RetirementPlan.find(@plan.id).milestones(as_of: AS_OF), "fi_25").reached_already
  end

  test "Coast FI measures to the plan's retirement date" do
    RetirementPlan::Milestones.expects(:new).with(has_entries(retirement_year: 2046, first_year: 2026, birth_year: 1980))
                              .returns(stub(all: []))

    @plan.milestones(as_of: AS_OF)
  end

  test "the milestones follow the simulation the page draws when it hands one in" do
    # Spending in retirement makes the retirement year matter to the path;
    # without it both simulations would be the same and this would prove nothing.
    @plan.streams.create!(kind: "expense", name: "Living costs", annual_amount: 20_000)
    drawn = @plan.simulation(as_of: AS_OF, retirement_year: 2030)
    assert_not_equal drawn.rows, @plan.simulation(as_of: AS_OF).rows, "the drawn path must differ from the plan's own"
    RetirementPlan::Milestones.expects(:new).with(has_entry(rows: drawn.rows)).returns(stub(all: []))

    @plan.milestones(as_of: AS_OF, simulation: drawn)
  end

  test "a plan that cannot be simulated has no milestones" do
    @plan.update!(birth_year: nil)

    assert_empty @plan.milestones(as_of: AS_OF)
  end
end

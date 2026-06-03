require "test_helper"

class Goal::RetirementTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @owner = users(:family_admin)
    @sibling = users(:family_member)
    @stranger = users(:empty)
  end

  test "STI: Goal.find returns Goal::Retirement instance" do
    retirement = Goal::Retirement.create!(
      family: @family,
      owner: @owner,
      name: "Retirement",
      target_amount: 1_000_000,
      currency: "USD"
    )

    fetched = Goal.find(retirement.id)
    assert_instance_of Goal::Retirement, fetched
    assert_equal "Goal::Retirement", fetched.type
  end

  test "requires owner" do
    retirement = Goal::Retirement.new(
      family: @family,
      name: "Retirement",
      target_amount: 1_000_000,
      currency: "USD"
    )

    assert_not retirement.valid?
    assert_includes retirement.errors[:owner], "can't be blank"
  end

  test "owner must belong to family" do
    retirement = Goal::Retirement.new(
      family: @family,
      owner: @stranger,
      name: "Retirement",
      target_amount: 1_000_000,
      currency: "USD"
    )

    assert_not retirement.valid?
    assert_match(/belong to the same family/i, retirement.errors[:owner].join(" "))
  end

  test "editable_by? owner true, sibling false, stranger false, nil false" do
    retirement = Goal::Retirement.create!(
      family: @family,
      owner: @owner,
      name: "Retirement",
      target_amount: 1_000_000,
      currency: "USD"
    )

    assert retirement.editable_by?(@owner)
    assert_not retirement.editable_by?(@sibling)
    assert_not retirement.editable_by?(@stranger)
    assert_not retirement.editable_by?(nil)
  end

  test "no linked_accounts required (parent validation bypassed)" do
    retirement = Goal::Retirement.new(
      family: @family,
      owner: @owner,
      name: "Retirement",
      target_amount: 1_000_000,
      currency: "USD"
    )

    assert retirement.valid?, retirement.errors.full_messages.to_sentence
  end

  test "for_owner bootstraps a valid plan without a target_amount" do
    # family_member has no retirement fixture, so this exercises the
    # create path (family_admin would just find retirement_bob).
    member = users(:family_member)

    plan = Goal::Retirement.for_owner(member)

    assert plan.persisted?
    assert_nil plan.target_amount
    assert_equal member.id, plan.user_id
    assert_equal member.family_id, plan.family_id
  end

  test "for_owner is idempotent (one plan per user)" do
    member = users(:family_member)
    first = Goal::Retirement.for_owner(member)
    second = Goal::Retirement.for_owner(member)
    assert_equal first.id, second.id
  end

  test "has pension sources, statements, adjustments, and bucket accounts" do
    plan = goals(:retirement_bob)
    assert_includes plan.pension_sources, pension_sources(:de_grv_bob)
    assert_includes plan.statements, goal_retirement_statements(:grv_2025)
    assert_includes plan.adjustments, goal_retirement_adjustments(:mortgage_paid_off)
    assert_includes plan.bucket_accounts, accounts(:investment)
  end

  test "adjustments are capped at ADJUSTMENTS_LIMIT" do
    plan = goals(:retirement_bob)

    (plan.adjustments.size...Goal::Retirement::ADJUSTMENTS_LIMIT).each do |i|
      plan.adjustments.build(from_age: 60, amount_today: -1, currency: "USD", label: "adj #{i}", ordinal: i + 1)
    end
    assert plan.valid?, plan.errors.full_messages.to_sentence

    plan.adjustments.build(from_age: 61, amount_today: -1, currency: "USD", label: "over", ordinal: 99)
    assert_not plan.valid?
    assert_includes plan.errors.attribute_names, :adjustments
  end

  test "forecast is nil until a birth year is set" do
    plan = goals(:retirement_bob)
    assert_nil plan.forecast
  end

  test "forecast wiring builds inputs from retirement_params" do
    plan = goals(:retirement_bob)
    plan.update!(retirement_params: {
      "birth_year" => Date.current.year - 45, "retire_age" => 60,
      "monthly_savings" => 1500, "target_spend" => 2500, "real_return_pct" => 4
    })
    plan = Goal.find(plan.id)

    assert_equal 45, plan.current_age
    inputs = plan.forecast_inputs
    assert_equal 60, inputs.retire_age
    assert_equal 95, inputs.terminal_age
    assert_in_delta 0.04, inputs.real_return, 0.0001
    assert_equal (1500 * 12).to_d, inputs.annual_savings
    assert_equal (2500 * 12).to_d, inputs.annual_target_spend
    assert_equal plan.pension_sources.count, inputs.payouts.length

    assert_instance_of Retirement::Fire::ForecastResult, plan.forecast
    assert_equal Date.new(Date.current.year - 45 + 60, 1, 1), plan.freedom_date
  end

  test "freedom_date is clamped to today when retire_age precedes current age" do
    plan = goals(:retirement_bob)
    plan.update!(retirement_params: { "birth_year" => Date.current.year - 50, "retire_age" => 40 })
    plan = Goal.find(plan.id)

    assert_equal 50, plan.current_age
    assert_equal 50, plan.clamped_retire_age          # not 40
    assert_equal Date.current.year, plan.freedom_date.year   # not a past year
  end

  test "glide_payload is nil without a birth year, structured once set" do
    plan = goals(:retirement_bob)
    assert_nil plan.glide_payload

    plan.update!(retirement_params: {
      "birth_year" => Date.current.year - 40, "retire_age" => 60,
      "monthly_savings" => 1000, "target_spend" => 2000, "real_return_pct" => 5
    })
    payload = Goal.find(plan.id).glide_payload

    assert_equal 40, payload[:current_age]
    assert_equal 60, payload[:retire_age]
    assert_operator payload[:series].length, :>, 1
    assert_equal payload[:series].length, payload[:shadow_series].length
    assert_equal payload[:series].length, payload[:band_low].length
    assert_kind_of Array, payload[:income]
    assert_kind_of Array, payload[:lumps]
  end

  test "lump_markers picks up lump payouts from params" do
    plan = goals(:retirement_bob)
    source = plan.pension_sources.find_by(payout_shape: "lump_plus_annuity")
    source.update!(params: { "lump_amount" => 30_000 })

    assert_equal [ { age: source.start_age, amount: 30_000 } ], plan.reload.lump_markers
  end

  test "fi_number is 25x the annual target spend" do
    plan = goals(:retirement_bob)
    plan.update!(retirement_params: { "birth_year" => Date.current.year - 40, "target_spend" => 3000 })
    assert_equal 3000 * 12 * 25, Goal.find(plan.id).fi_number
  end
end

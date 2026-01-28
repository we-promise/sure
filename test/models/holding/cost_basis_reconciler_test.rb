require "test_helper"

class Holding::CostBasisReconcilerTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(
      name: "Test Investment",
      balance: 20000,
      currency: "USD",
      accountable: Investment.new
    )
    @security = securities(:aapl)
  end

  test "new holding uses incoming cost_basis" do
    result = Holding::CostBasisReconciler.reconcile(
      existing_holding: nil,
      incoming_cost_basis: BigDecimal("150"),
      incoming_source: "provider"
    )

    assert result[:should_update]
    assert_equal BigDecimal("150"), result[:cost_basis]
    assert_equal "provider", result[:cost_basis_source]
  end

  test "new holding with nil cost_basis gets nil source" do
    result = Holding::CostBasisReconciler.reconcile(
      existing_holding: nil,
      incoming_cost_basis: nil,
      incoming_source: "provider"
    )

    assert result[:should_update]
    assert_nil result[:cost_basis]
    assert_nil result[:cost_basis_source]
  end

  test "locked holding is never overwritten" do
    holding = @account.holdings.create!(
      security: @security,
      date: Date.current,
      qty: 10,
      price: 200,
      amount: 2000,
      currency: "USD",
      cost_basis: BigDecimal("175"),
      cost_basis_source: "manual",
      cost_basis_locked: true
    )

    result = Holding::CostBasisReconciler.reconcile(
      existing_holding: holding,
      incoming_cost_basis: BigDecimal("200"),
      incoming_source: "calculated"
    )

    assert_not result[:should_update]
    assert_equal BigDecimal("175"), result[:cost_basis]
    assert_equal "manual", result[:cost_basis_source]
  end

  test "calculated overwrites provider" do
    holding = @account.holdings.create!(
      security: @security,
      date: Date.current,
      qty: 10,
      price: 200,
      amount: 2000,
      currency: "USD",
      cost_basis: BigDecimal("150"),
      cost_basis_source: "provider",
      cost_basis_locked: false
    )

    result = Holding::CostBasisReconciler.reconcile(
      existing_holding: holding,
      incoming_cost_basis: BigDecimal("175"),
      incoming_source: "calculated"
    )

    assert result[:should_update]
    assert_equal BigDecimal("175"), result[:cost_basis]
    assert_equal "calculated", result[:cost_basis_source]
  end

  test "provider does not overwrite calculated" do
    holding = @account.holdings.create!(
      security: @security,
      date: Date.current,
      qty: 10,
      price: 200,
      amount: 2000,
      currency: "USD",
      cost_basis: BigDecimal("175"),
      cost_basis_source: "calculated",
      cost_basis_locked: false
    )

    result = Holding::CostBasisReconciler.reconcile(
      existing_holding: holding,
      incoming_cost_basis: BigDecimal("150"),
      incoming_source: "provider"
    )

    assert_not result[:should_update]
    assert_equal BigDecimal("175"), result[:cost_basis]
    assert_equal "calculated", result[:cost_basis_source]
  end

  test "provider does not overwrite manual" do
    holding = @account.holdings.create!(
      security: @security,
      date: Date.current,
      qty: 10,
      price: 200,
      amount: 2000,
      currency: "USD",
      cost_basis: BigDecimal("175"),
      cost_basis_source: "manual",
      cost_basis_locked: false
    )

    result = Holding::CostBasisReconciler.reconcile(
      existing_holding: holding,
      incoming_cost_basis: BigDecimal("150"),
      incoming_source: "provider"
    )

    assert_not result[:should_update]
    assert_equal BigDecimal("175"), result[:cost_basis]
    assert_equal "manual", result[:cost_basis_source]
  end

  test "zero provider cost_basis treated as unknown" do
    result = Holding::CostBasisReconciler.reconcile(
      existing_holding: nil,
      incoming_cost_basis: BigDecimal("0"),
      incoming_source: "provider"
    )

    assert result[:should_update]
    assert_nil result[:cost_basis]
    assert_nil result[:cost_basis_source]
  end

  test "nil incoming cost_basis does not overwrite existing" do
    holding = @account.holdings.create!(
      security: @security,
      date: Date.current,
      qty: 10,
      price: 200,
      amount: 2000,
      currency: "USD",
      cost_basis: BigDecimal("175"),
      cost_basis_source: "provider",
      cost_basis_locked: false
    )

    result = Holding::CostBasisReconciler.reconcile(
      existing_holding: holding,
      incoming_cost_basis: nil,
      incoming_source: "calculated"
    )

    # Even though calculated > provider, nil incoming shouldn't overwrite existing value
    assert_not result[:should_update]
    assert_equal BigDecimal("175"), result[:cost_basis]
    assert_equal "provider", result[:cost_basis_source]
  end
end

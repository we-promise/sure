require "test_helper"

# Verifies that provider sync never mutates or claims a user-created manual holding
# (source = "manual"). Covers the early guard path (external_id present), the
# find_or_initialize_by path (no external_id), and the RecordNotUnique rescue path.
class Account::ProviderImportAdapterManualHoldingTest < ActiveSupport::TestCase
  setup do
    @investment_account = accounts(:investment)
    @adapter = Account::ProviderImportAdapter.new(@investment_account)
    @security = securities(:aapl)

    item = SimplefinItem.create!(family: families(:dylan_family), name: "SF Manual Test", access_url: "https://example.com/access")
    sfa = SimplefinAccount.create!(
      simplefin_item: item,
      name: "SF Invest Manual",
      account_id: "sf_inv_manual_test",
      currency: "USD",
      account_type: "investment",
      current_balance: 1000
    )
    @ap = AccountProvider.create!(account: @investment_account, provider: sfa)

    # A date with no existing fixture holdings so we fully control the state
    @holding_date = Date.today - 6.days

    @manual_holding = @investment_account.holdings.create!(
      security: @security,
      date: @holding_date,
      qty: 50,
      price: 150,
      amount: 7500,
      currency: "USD",
      cost_basis: 120,
      cost_basis_source: "manual",
      source: "manual",
      account_provider_id: nil
    )
  end

  # =========================================================================
  # Early guard (external_id path) — the pre-save guard must fire
  # =========================================================================

  test "early guard returns manual holding without any mutation when external_id is present" do
    assert_no_difference "@investment_account.holdings.count" do
      result = @adapter.import_holding(
        security: @security,
        quantity: 10,
        amount: 2000,
        currency: "USD",
        date: @holding_date,
        price: 200,
        cost_basis: 180,
        external_id: "ext-manual-guard",
        source: "simplefin",
        account_provider_id: @ap.id
      )

      assert_equal @manual_holding.id, result.id
    end

    @manual_holding.reload
    assert_equal 50,   @manual_holding.qty,    "qty must not be changed"
    assert_equal 150,  @manual_holding.price,  "price must not be changed"
    assert_equal 7500, @manual_holding.amount, "amount must not be changed"
    assert_nil @manual_holding.account_provider_id, "account_provider_id must remain nil"
    assert_nil @manual_holding.external_id,         "external_id must remain nil"
    assert_equal "manual", @manual_holding.source,  "source must remain manual"
    assert_equal BigDecimal("120"), @manual_holding.cost_basis, "cost_basis must not be changed"
  end

  # =========================================================================
  # find_or_initialize_by path (no external_id) + RecordNotUnique rescue
  #
  # When no external_id is given, find_or_initialize_by scopes out manual holdings.
  # The subsequent save! raises RecordNotUnique (the manual holding occupies the
  # composite key). The rescue block detects the manual holding and skips mutation.
  # =========================================================================

  test "rescue block returns manual holding without mutation when composite key collides via no-external_id path" do
    assert_no_difference "@investment_account.holdings.count" do
      result = @adapter.import_holding(
        security: @security,
        quantity: 10,
        amount: 2000,
        currency: "USD",
        date: @holding_date,
        price: 200,
        source: "simplefin",
        account_provider_id: @ap.id
        # no external_id — triggers find_or_initialize_by path
      )

      assert_equal @manual_holding.id, result.id
    end

    @manual_holding.reload
    assert_equal 50,   @manual_holding.qty,    "qty must not be changed"
    assert_equal 7500, @manual_holding.amount, "amount must not be changed"
    assert_nil @manual_holding.account_provider_id, "account_provider_id must remain nil"
    assert_equal "manual", @manual_holding.source
    assert_equal BigDecimal("120"), @manual_holding.cost_basis
  end

  # =========================================================================
  # Same-provider holding is still updated on re-import (no regression)
  # =========================================================================

  test "same-provider provider holding is updated on re-import" do
    provider_date = @holding_date - 1.day

    provider_holding = @investment_account.holdings.create!(
      security: @security,
      date: provider_date,
      qty: 5,
      price: 100,
      amount: 500,
      currency: "USD",
      source: "provider",
      account_provider_id: @ap.id,
      external_id: "ext-same-provider-1"
    )

    assert_no_difference "@investment_account.holdings.count" do
      result = @adapter.import_holding(
        security: @security,
        quantity: 8,
        amount: 800,
        currency: "USD",
        date: provider_date,
        price: 100,
        external_id: "ext-same-provider-1",
        source: "simplefin",
        account_provider_id: @ap.id
      )

      assert_equal provider_holding.id, result.id
    end

    provider_holding.reload
    assert_equal 8,          provider_holding.qty
    assert_equal 800,        provider_holding.amount
    assert_equal "provider", provider_holding.source
  end

  # =========================================================================
  # Unowned calculated holding is still adoptable (no regression)
  # =========================================================================

  test "unowned calculated holding is adopted by provider import" do
    calc_date = @holding_date - 2.days

    calculated_holding = @investment_account.holdings.create!(
      security: @security,
      date: calc_date,
      qty: 3,
      price: 150,
      amount: 450,
      currency: "USD",
      source: "calculated",
      account_provider_id: nil
    )

    assert_no_difference "@investment_account.holdings.count" do
      result = @adapter.import_holding(
        security: @security,
        quantity: 10,
        amount: 1500,
        currency: "USD",
        date: calc_date,
        price: 150,
        external_id: "ext-adopt-calculated",
        source: "simplefin",
        account_provider_id: @ap.id
      )

      assert_equal calculated_holding.id, result.id
    end

    calculated_holding.reload
    assert_equal 10,        calculated_holding.qty
    assert_equal @ap.id,    calculated_holding.account_provider_id
    assert_equal "provider", calculated_holding.source
    assert_equal "ext-adopt-calculated", calculated_holding.external_id
  end

  # =========================================================================
  # New holding gets source = "provider"
  # =========================================================================

  test "newly imported provider holding has source set to provider" do
    new_date = @holding_date - 3.days

    holding = @adapter.import_holding(
      security: @security,
      quantity: 5,
      amount: 750,
      currency: "USD",
      date: new_date,
      price: 150,
      external_id: "ext-new-provider-source",
      source: "simplefin",
      account_provider_id: @ap.id
    )

    assert_equal "provider", holding.source
  end
end

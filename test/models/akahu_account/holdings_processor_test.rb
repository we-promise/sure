require "test_helper"

class AkahuAccount::HoldingsProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @akahu_item = AkahuItem.create!(
      family: @family,
      name: "Test Akahu",
      app_token: "akahu-app-credential",
      user_token: "akahu-user-credential"
    )
  end

  test "unscales Kernel share counts and keeps cost basis matching Akahu returns" do
    akahu_account = build_synthetic_account(
      portfolio: [ {
        "name" => "Global 100",
        "value" => 103_157.91,
        "shares" => 914_568,
        "returns" => 5_289.51,
        "fund_id" => "143705",
        "currency" => "NZD",
        "logo" => "https://example.test/logo.png"
      } ]
    )
    account = link_account(akahu_account)

    result = AkahuAccount::HoldingsProcessor.new(akahu_account).process

    assert_equal 1, result[:imported]
    holding = account.holdings.sole

    assert_equal BigDecimal("9145.68"), holding.qty
    assert_equal BigDecimal("103157.91"), holding.amount
    assert_in_delta (holding.amount / holding.qty), holding.price, 0.0001
    assert_equal "provider", holding.cost_basis_source
    assert_in_delta 5_289.51, (holding.amount - (holding.cost_basis * holding.qty)), 0.5

    security = holding.security
    assert security.offline?
    assert_equal "provider_managed", security.offline_reason
    assert_equal "AKAHU-KERNEL-WEALTH-143705", security.ticker
    assert_equal "Global 100", security.name
  end

  test "keeps unscaled share counts when implied unit price is sane" do
    akahu_account = build_synthetic_account(
      portfolio: [ {
        "name" => "Global 100",
        "value" => 106_663.18,
        "shares" => 9_145.6786,
        "returns" => 5_289.51,
        "fund_id" => "143705",
        "currency" => "NZD"
      } ]
    )
    account = link_account(akahu_account)

    AkahuAccount::HoldingsProcessor.new(akahu_account).process

    holding = account.holdings.sole
    assert_equal BigDecimal("9145.6786"), holding.qty
    assert_equal BigDecimal("106663.18"), holding.amount
  end

  test "imports a holding for a single-fund Simplicity-shaped account" do
    akahu_account = build_akahu_account(
      account_id: "acc_simplicity",
      portfolio: [ {
        "name" => "Growth",
        "value" => 87_744.93,
        "shares" => 35_704.64,
        "price" => 2.4656,
        "returns" => 27_808.10,
        "fund_id" => "730001",
        "currency" => "NZD"
      } ]
    )
    account = link_account(akahu_account)

    result = AkahuAccount::HoldingsProcessor.new(akahu_account).process

    assert_equal 1, result[:imported]
    holding = account.holdings.sole
    assert_equal BigDecimal("35704.64"), holding.qty
    assert_equal BigDecimal("87744.93"), holding.amount
    assert_in_delta 27_808.10, (holding.amount - (holding.cost_basis * holding.qty)), 1.0
  end

  test "does not import exchange-listed portfolios as a managed-fund holding" do
    akahu_account = build_akahu_account(
      account_id: "acc_sharesies",
      portfolio: [ {
        "name" => "Spark New Zealand",
        "value" => 565.78,
        "shares" => 300,
        "symbol" => "SPK",
        "fund_id" => "28184589"
      } ]
    )
    account = link_account(akahu_account)

    assert_nil AkahuAccount::HoldingsProcessor.new(akahu_account).process
    assert_equal 0, account.holdings.count
  end

  test "does not import holdings for the blended parent of a split portfolio" do
    akahu_account = build_akahu_account(
      account_id: "acc_kernel",
      portfolio: [
        { "name" => "Global 100", "value" => 103_157.91, "returns" => 5_289.51, "fund_id" => "143705" },
        { "name" => "High Growth", "value" => 70_741.98, "returns" => 1_598.64, "fund_id" => "157210" }
      ]
    )
    account = link_account(akahu_account)

    assert_nil AkahuAccount::HoldingsProcessor.new(akahu_account).process
    assert_equal 0, account.holdings.count
  end

  test "omits cost basis when lifetime returns exceed remaining value" do
    akahu_account = build_synthetic_account(
      portfolio: [ {
        "name" => "High Growth",
        "value" => 70_820.42,
        "returns" => 128_689.29,
        "fund_id" => "157210",
        "currency" => "NZD"
      } ]
    )
    account = link_account(akahu_account)

    AkahuAccount::HoldingsProcessor.new(akahu_account).process

    holding = account.holdings.sole
    assert_equal BigDecimal("70820.42"), holding.amount
    assert_nil holding.cost_basis
  end

  test "skips accounts without a portfolio" do
    akahu_account = build_synthetic_account(portfolio: nil)
    account = link_account(akahu_account)

    assert_nil AkahuAccount::HoldingsProcessor.new(akahu_account).process
    assert_equal 0, account.holdings.count
  end

  test "skips non-investment accounts" do
    akahu_account = build_synthetic_account(
      portfolio: [ { "name" => "Global 100", "value" => 10.0, "returns" => 1.0, "fund_id" => "143705" } ]
    )
    account = link_account(akahu_account, accountable: Depository.new)

    assert_nil AkahuAccount::HoldingsProcessor.new(akahu_account).process
    assert_equal 0, account.holdings.count
  end

  private

    def build_synthetic_account(portfolio:)
      build_akahu_account(account_id: "acc_kernel::143705", portfolio: portfolio)
    end

    def build_akahu_account(account_id:, portfolio:)
      meta = portfolio.nil? ? {} : { "portfolio" => portfolio }

      AkahuAccount.create!(
        akahu_item: @akahu_item,
        name: "Kernel Wealth - Global 100",
        account_id: account_id,
        currency: "NZD",
        current_balance: 1_000,
        institution_metadata: { "name" => "Kernel Wealth" },
        raw_payload: { "_id" => account_id, "meta" => meta }
      )
    end

    def link_account(akahu_account, accountable: Investment.new)
      account = Account.create!(
        family: @family,
        name: akahu_account.name,
        accountable: accountable,
        balance: 1_000,
        cash_balance: 0,
        currency: "NZD"
      )
      AccountProvider.create!(account: account, provider: akahu_account)
      account
    end
end

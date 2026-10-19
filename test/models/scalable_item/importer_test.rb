require "test_helper"
require Rails.root.join("test/support/scalable_test_helper")

class ScalableItem::ImporterTest < ActiveSupport::TestCase
  include ScalableTestHelper

  setup do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    Account.any_instance.stubs(:sync_later).returns(nil)
    @owner = scalable_owner
    @item = scalable_connected_item(owner: @owner)
    @credentials = @item.credentials_data.deep_dup
    @owner_id = @item.owner_id
  end

  test "imports a native cash-inclusive portfolio idempotently without changing its owner or session" do
    snapshot = normalized_snapshot

    ScalableItem::Importer.new(@item).import(snapshot: snapshot)
    ScalableItem::Importer.new(@item).import(snapshot: snapshot)

    provider_account = @item.scalable_accounts.sole
    account = provider_account.usable_account
    holding = provider_account.holdings.sole
    assert_equal "broker-portfolio", provider_account.uid
    assert_equal "EUR", provider_account.currency
    assert_equal BigDecimal("50"), provider_account.cash_balance
    assert_equal BigDecimal("150"), provider_account.current_balance
    assert_equal BigDecimal("3"), holding.qty
    assert_equal BigDecimal("100"), holding.amount
    assert_equal BigDecimal("33.3333"), holding.price
    assert_nil holding.cost_basis
    assert_equal BigDecimal("50"), account.cash_balance
    assert_equal BigDecimal("150"), account.balance
    assert_equal @owner_id, @item.reload.owner_id
    assert_equal @credentials, @item.credentials_data
    assert_equal 1, @item.scalable_accounts.count
    assert_equal 1, AccountProvider.where(provider: provider_account).count
  end

  test "clears old generated projections before a new snapshot reuses the valuation date" do
    first_date = Date.current - 1.day
    first_observation = first_date.in_time_zone + 12.hours
    current_date = first_date.next_day

    travel_to(first_observation) do
      initial = normalized_snapshot(observed_at: Time.current, valuation: "100", cash_balance: "50")
      ScalableItem::Importer.new(@item).import(snapshot: initial)
    end
    provider_account = @item.scalable_accounts.sole
    account = provider_account.usable_account

    travel_to(current_date.in_time_zone + 12.hours) do
      Holding::Materializer.new(account, strategy: :reverse).materialize_holdings
      prior_projection = account.holdings.find_by!(date: current_date, account_provider_id: nil)
      assert_equal BigDecimal("100"), prior_projection.amount
      assert_equal BigDecimal("33.3333"), prior_projection.price

      refreshed = normalized_snapshot(observed_at: first_observation, valuation: "120", cash_balance: "45")
      ScalableItem::Importer.new(@item).import(snapshot: refreshed)
      assert_empty account.holdings.where(account_provider_id: nil)

      Holding::Materializer.new(account, strategy: :reverse).materialize_holdings
      provider_holding = account.holdings.find_by!(date: current_date, account_provider_id: provider_account.account_provider.id)
      assert_equal BigDecimal("120"), provider_holding.amount
      assert_equal BigDecimal("40"), provider_holding.price
      assert_equal BigDecimal("45"), account.reload.cash_balance
      assert_equal BigDecimal("165"), account.balance
      assert_equal BigDecimal("165"), provider_account.reload.current_balance
      assert_equal @owner_id, @item.reload.owner_id
      assert_equal @credentials, @item.credentials_data
    end
  end

  test "rejects rebinding a saved portfolio to another broker account" do
    ScalableItem::Importer.new(@item).import(snapshot: normalized_snapshot)
    provider_account = @item.scalable_accounts.sole
    account_id = provider_account.account.id

    error = assert_raises(Provider::Scalable::Error) do
      ScalableItem::Importer.new(@item).import(snapshot: normalized_snapshot(account_id: "another-account"))
    end

    assert_equal "account_conflict", error.code
    assert_equal account_id, provider_account.reload.account.id
    assert_equal "broker-account", JSON.parse(provider_account.raw_metadata).fetch("account_id")
  end

  test "rejects an older source valuation even when the snapshot was fetched later" do
    first = normalized_snapshot
    ScalableItem::Importer.new(@item).import(snapshot: first)
    provider_account = @item.scalable_accounts.sole
    older_valuation = first.accounts.sole.valuation_timestamp - 1.hour

    error = assert_raises(Provider::Scalable::Error) do
      ScalableItem::Importer.new(@item).import(snapshot: normalized_snapshot(observed_at: older_valuation, valuation: "90"))
    end

    assert_equal "stale_snapshot", error.code
    assert_equal BigDecimal("150"), provider_account.reload.current_balance
    assert_equal @credentials, @item.reload.credentials_data
  end

  test "does not silently relink an unlinked saved portfolio to a duplicate native account" do
    ScalableItem::Importer.new(@item).import(snapshot: normalized_snapshot)
    provider_account = @item.scalable_accounts.sole
    original_account_id = provider_account.account.id
    account_count = @owner.family.accounts.count
    provider_account.account_provider.destroy!

    error = assert_raises(Provider::Scalable::Error) do
      ScalableItem::Importer.new(@item).import(snapshot: normalized_snapshot)
    end

    assert_equal "account_conflict", error.code
    assert_equal account_count, @owner.family.accounts.count
    assert_equal original_account_id, Account.find(original_account_id).id
    assert_nil provider_account.reload.account_provider
  end

  test "rejects manual or foreign unowned holdings and leaves them untouched" do
    ScalableItem::Importer.new(@item).import(snapshot: normalized_snapshot)
    provider_account = @item.scalable_accounts.sole
    account = provider_account.account
    manual_security = Security.create!(ticker: "US5949181045", name: "Synthetic Microsoft", offline: true)
    manual = account.holdings.create!(security: manual_security, date: Date.current, qty: 1,
      price: 20, amount: 20, currency: "EUR", external_id: "manual-import")

    error = assert_raises(Provider::Scalable::Error) do
      ScalableItem::Importer.new(@item).import(snapshot: normalized_snapshot(valuation: "120"))
    end

    assert_equal "account_conflict", error.code
    assert_equal BigDecimal("20"), manual.reload.amount
    assert_equal BigDecimal("150"), provider_account.reload.current_balance
  end

  test "rejects mismatched generated rows instead of deleting user data" do
    initial_date = Date.current - 1.day
    travel_to(initial_date.in_time_zone + 12.hours) do
      ScalableItem::Importer.new(@item).import(snapshot: normalized_snapshot(observed_at: Time.current))
    end
    provider_account = @item.scalable_accounts.sole
    account = provider_account.account
    security = provider_account.holdings.sole.security
    mismatch = account.holdings.create!(security: security, date: Date.current, qty: 3,
      price: 30, amount: 90, currency: "EUR")

    error = assert_raises(Provider::Scalable::Error) do
      ScalableItem::Importer.new(@item).import(snapshot: normalized_snapshot(valuation: "120"))
    end

    assert_equal "account_conflict", error.code
    assert_equal BigDecimal("90"), mismatch.reload.amount
    assert_equal BigDecimal("150"), provider_account.reload.current_balance
  end

  private

    def normalized_snapshot(uid: "broker-portfolio", account_id: "broker-account", observed_at: Time.current,
      valuation: "100", cash_balance: "50")
      now = Time.current
      position = {
        "isin" => "US0378331005",
        "name" => "Synthetic Apple position",
        "type" => "EQUITY",
        "inventory" => { "position" => { "filled" => "3", "pending" => "0", "blocked" => "0", "fifoPrice" => "25" } },
        "portfolioIsinPerformance" => { "valuation" => valuation, "currency" => "EUR" },
        "quoteTick" => nil
      }
      holdings_total = BigDecimal(valuation)
      cash = BigDecimal(cash_balance)
      discovery = { "account" => { "id" => account_id, "brokerPortfolios" => [ { "id" => uid } ] } }
      response = {
        "portfolio_id" => uid,
        "overview" => { "account" => { "id" => account_id, "brokerPortfolio" => { "id" => uid,
          "valuation" => { "valuation" => (holdings_total + cash).to_s, "securitiesValuation" => holdings_total.to_s,
            "cryptoValuation" => "0", "timestampUtc" => { "time" => observed_at.iso8601 },
            "lastInventoryUpdateTimestampUtc" => { "time" => observed_at.iso8601 } } } } },
        "cash_breakdown" => { "account" => { "id" => account_id, "brokerPortfolio" => { "id" => uid,
          "payments" => { "buyingPower" => { "cashBalance" => cash_balance, "loaned" => "0", "cashAvailableToInvest" => "500" } } } } },
        "holdings" => { "account" => { "id" => account_id, "brokerPortfolio" => { "id" => uid,
          "inventory" => { "items" => [ position ] } } } }
      }

      ScalableItem::PortfolioNormalizer.new(now: now).normalize(
        discovery: discovery,
        portfolio_responses: [ response ],
        person_identity: @item.person_identity,
        connection_generation: @item.connection_generation,
        fetched_at: now
      )
    end
end

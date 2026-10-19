require "test_helper"
require Rails.root.join("test/support/scalable_test_helper")

class ScalableItem::SyncerTest < ActiveSupport::TestCase
  include ScalableTestHelper

  setup do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    Account.any_instance.stubs(:sync_later).returns(nil)
    @item = scalable_connected_item
  end

  test "reads every discovered broker portfolio using the separate verified account ID" do
    now = Time.current
    person_id = @item.person_identity
    account_id = "distinct-broker-account"
    portfolio_ids = %w[portfolio-one portfolio-two]
    discovery = { "account" => { "id" => account_id, "brokerPortfolios" => portfolio_ids.map { |id| { "id" => id } } } }
    provider = mock("scalable provider")
    provider.stubs(:person_identity).returns(person_id)
    provider.expects(:read).with(:broker_portfolios, variables: { "id" => person_id }).returns(discovery)

    portfolio_ids.each do |portfolio_id|
      variables = { "accountId" => account_id, "portfolioId" => portfolio_id }
      provider.expects(:read).with(:broker_overview, variables: variables.merge("includeYearToDate" => false))
        .returns(overview_response(account_id, portfolio_id, now))
      provider.expects(:read).with(:broker_cash_breakdown, variables: variables)
        .returns(cash_response(account_id, portfolio_id))
      provider.expects(:read).with(:broker_holdings,
        variables: variables.merge("includeYearToDate" => false, "quoteSource" => nil))
        .returns(holdings_response(account_id, portfolio_id))
    end
    @item.stubs(:with_authenticated_provider).yields(provider)

    ScalableItem::Syncer.new(@item).perform_sync(nil)

    assert_equal portfolio_ids, @item.scalable_accounts.order(:uid).pluck(:uid)
    assert_equal 2, @item.accounts.distinct.count
  end

  test "does no provider reads during a saved cooldown" do
    @item.update!(next_sync_at: 5.minutes.from_now)
    @item.expects(:with_authenticated_provider).never

    ScalableItem::Syncer.new(@item).perform_sync(nil)

    assert_equal 0, @item.scalable_accounts.count
  end

  private

    def overview_response(account_id, portfolio_id, observed_at)
      { "account" => { "id" => account_id, "brokerPortfolio" => { "id" => portfolio_id,
        "valuation" => { "valuation" => "25", "securitiesValuation" => "0", "cryptoValuation" => "0",
          "timestampUtc" => { "time" => observed_at.iso8601 },
          "lastInventoryUpdateTimestampUtc" => { "time" => observed_at.iso8601 } } } } }
    end

    def cash_response(account_id, portfolio_id)
      { "account" => { "id" => account_id, "brokerPortfolio" => { "id" => portfolio_id,
        "payments" => { "buyingPower" => { "cashBalance" => "25", "loaned" => "0", "cashAvailableToInvest" => "25" } } } } }
    end

    def holdings_response(account_id, portfolio_id)
      { "account" => { "id" => account_id, "brokerPortfolio" => { "id" => portfolio_id, "inventory" => { "items" => [] } } } }
    end
end

require "test_helper"

class Provider::Scalable::ReadQueriesTest < ActiveSupport::TestCase
  test "exposes only fixed GraphQL read documents with portfolio identity and required snapshot fields" do
    documents = Provider::Scalable::ReadQueries::DOCUMENTS

    assert_equal %i[broker_portfolios broker_overview broker_cash_breakdown broker_holdings], documents.keys
    assert_equal %w[ResolveBrokerIds BrokerOverview BrokerLimits BrokerHoldings], documents.values.map { |document| document.fetch(:name) }
    documents.each_value do |document|
      assert_match(/\A\s*query\b/, document.fetch(:query))
      refute_match(/\bmutation\b/i, document.fetch(:query))
    end

    assert_includes documents.fetch(:broker_portfolios).fetch(:query), "brokerPortfolios"
    assert_includes documents.fetch(:broker_overview).fetch(:query), "securitiesValuation"
    assert_includes documents.fetch(:broker_cash_breakdown).fetch(:query), "cashBalance"
    assert_includes documents.fetch(:broker_cash_breakdown).fetch(:query), "loaned"
    assert_includes documents.fetch(:broker_holdings).fetch(:query), "portfolioIsinPerformance"
    assert_includes documents.fetch(:broker_holdings).fetch(:query), "filled"
  end
end

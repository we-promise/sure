require "test_helper"

class Provider::Scalable::ReadQueriesTest < ActiveSupport::TestCase
  test "exposes only fixed GraphQL read documents with portfolio identity and required snapshot fields" do
    documents = Provider::Scalable::ReadQueries::DOCUMENTS

    assert_equal %i[
      broker_portfolios broker_overview broker_cash_breakdown broker_holdings broker_transactions broker_transaction_details
    ], documents.keys
    assert_equal %w[
      ResolveBrokerIds BrokerOverview BrokerLimits BrokerHoldings BrokerTransactions BrokerTransactionDetails
    ], documents.values.map { |document| document.fetch(:name) }
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

    transactions = documents.fetch(:broker_transactions).fetch(:query)
    assert_includes transactions, "account(id: $accountId)"
    assert_match(/account\(id: \$accountId\)\s*\{\s*id\s*brokerPortfolio\(id: \$portfolioId\)\s*\{\s*id/, transactions)
    assert_includes transactions, "moreTransactions(input: $input)"
    assert_includes transactions, "cursor"
    assert_includes transactions, "total"
    assert_includes transactions, "cashTransactionType"
    assert_includes transactions, "amount"

    details = documents.fetch(:broker_transaction_details).fetch(:query)
    assert_match(/account\(id: \$accountId\)\s*\{\s*id\s*brokerPortfolio\(id: \$portfolioId\)\s*\{\s*id/, details)
    assert_includes details, "transactionDetails(id: $transactionId)"
    assert_includes details, "isPending"
    assert_includes details, "isCancellation"
    assert_includes details, "cashTransactionHistory: transactionHistory"
    assert_includes details, "description"
    refute_includes details, "tradeTransactionAmounts"
    refute_includes details, "orderKind"
    refute_includes details, "limitPrice"
  end
end

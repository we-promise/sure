require "test_helper"

class ProviderBanksMercuryPaginationTest < ActiveSupport::TestCase
  class FakeClient
    def initialize(pages)
      @pages = pages
      @call = 0
    end

    def get(path, query: {}, headers: {})
      res = @pages[@call] || {}
      @call += 1
      res
    end
  end

  test "list_transactions aggregates paginated responses by limit/offset" do
    provider = Provider::Banks::Mercury.new(api_key: "x")
    pages = [
      { transactions: [ { id: "a1", amount: 1, date: "2025-01-01" } ] },
      { transactions: [ { id: "a2", amount: 2, date: "2025-01-02" } ] }
    ]
    provider.stubs(:client).returns(FakeClient.new(pages))

    txs = provider.list_transactions(account_id: "acct", start_date: Date.today - 7, end_date: Date.today)
    ids = txs.map { |t| t[:id] }
    assert_equal ["a1", "a2"], ids
  end
end

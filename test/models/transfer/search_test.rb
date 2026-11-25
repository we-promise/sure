require "test_helper"

class Transfer::SearchTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @checking = create_account("Search Checking")
    @savings = create_account("Search Savings")
    @brokerage = create_account("Search Brokerage")

    @january = create_transfer(@checking, @savings, date: Date.new(2024, 1, 15), status: "confirmed")
    @february = create_transfer(@savings, @brokerage, date: Date.new(2024, 2, 10))
    @scope = Transfer.where(id: [ @january, @february ])
  end

  test "without filters returns the scope it is given" do
    assert_equal [ @february, @january ].sort_by(&:id), Transfer::Search.new(@scope).transfers_scope.sort_by(&:id)
  end

  test "filters by status" do
    assert_equal [ @january ], Transfer::Search.new(@scope, filters: { status: "confirmed" }).transfers_scope.to_a
    assert_equal [ @february ], Transfer::Search.new(@scope, filters: { status: "pending" }).transfers_scope.to_a
  end

  test "filters by an account on either leg" do
    assert_equal [ @january ], search(account_id: @checking.id).to_a
    assert_equal [ @february ], search(account_id: @brokerage.id).to_a
    assert_equal [ @february, @january ].sort_by(&:id), search(account_id: @savings.id).sort_by(&:id)
  end

  test "filters by dates on either leg, inclusive" do
    partial = create_transfer(@checking, @brokerage, date: Date.new(2024, 2, 10), inflow_date: Date.new(2024, 2, 12))
    scope = Transfer.where(id: [ @january, @february, partial ])

    on_tenth = Transfer::Search.new(scope, filters: { start_date: Date.new(2024, 2, 10), end_date: Date.new(2024, 2, 10) }).transfers_scope
    assert_equal [ @february, partial ].sort_by(&:id), on_tenth.sort_by(&:id)

    on_twelfth = Transfer::Search.new(scope, filters: { start_date: Date.new(2024, 2, 12) }).transfers_scope
    assert_equal [ partial ], on_twelfth.to_a

    until_january = Transfer::Search.new(scope, filters: { end_date: Date.new(2024, 1, 15) }).transfers_scope
    assert_equal [ @january ], until_january.to_a
  end

  test "combines account and date filters" do
    assert_equal [ @february ], search(account_id: @savings.id, start_date: Date.new(2024, 2, 1)).to_a
    assert_empty search(account_id: @checking.id, start_date: Date.new(2024, 2, 1))
  end

  test "filters rejected transfers the same way" do
    rejected_outflow = create_transaction(@checking, amount: 30, date: Date.new(2024, 3, 1))
    rejected_inflow = create_transaction(@brokerage, amount: -30, date: Date.new(2024, 3, 1))
    rejected = RejectedTransfer.create!(outflow_transaction: rejected_outflow, inflow_transaction: rejected_inflow)
    scope = RejectedTransfer.where(id: rejected)

    assert_equal [ rejected ], Transfer::Search.new(scope, filters: { account_id: @brokerage.id, start_date: Date.new(2024, 3, 1) }).transfers_scope.to_a
    assert_empty Transfer::Search.new(scope, filters: { account_id: @savings.id }).transfers_scope
  end

  test "never widens the scope it is given" do
    narrowed = Transfer.where(id: @january)

    assert_empty Transfer::Search.new(narrowed, filters: { account_id: @brokerage.id }).transfers_scope
    assert_empty Transfer::Search.new(narrowed, filters: { start_date: Date.new(2024, 2, 1) }).transfers_scope
  end

  private

    def search(filters)
      Transfer::Search.new(@scope, filters:).transfers_scope
    end

    def create_account(name)
      @family.accounts.create!(name:, accountable: Depository.new, balance: 0, currency: "USD")
    end

    def create_transfer(from, to, date:, inflow_date: date, status: "pending")
      Transfer.create!(
        outflow_transaction: create_transaction(from, amount: 100, date:),
        inflow_transaction: create_transaction(to, amount: -100, date: inflow_date),
        status:
      )
    end

    def create_transaction(account, amount:, date:)
      account.entries.create!(
        date:, amount:, name: "Search transfer leg", currency: "USD",
        entryable: Transaction.new(kind: "funds_movement")
      ).entryable
    end
end

require "test_helper"

class AccountStatement::SearchTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @scope = @family.account_statements

    @january = create_statement(accounts(:depository), "date,amount\n2024-01-01,1\n", Date.new(2024, 1, 1), Date.new(2024, 1, 31))
    @february = create_statement(nil, "date,amount\n2024-02-01,2\n", Date.new(2024, 2, 1), Date.new(2024, 2, 29))
  end

  test "returns the whole scope when no filter is set" do
    assert_equal @scope.ids.sort, AccountStatement::Search.new(@scope).account_statements_scope.ids.sort
  end

  test "account_id keeps statements linked to that account" do
    assert_equal [ @january ], search(account_id: accounts(:depository).id).to_a
  end

  test "review_status keeps statements in that state" do
    assert_equal [ @february ], search(review_status: "unmatched").to_a
    assert_equal [ @january ], search(review_status: "linked").to_a
  end

  test "content_sha256 matches the stored lowercase hex whatever its case" do
    assert_equal [ @february ], search(content_sha256: @february.content_sha256.upcase).to_a
  end

  test "dates keep statements whose period overlaps the range" do
    assert_equal [ @january ], search(start_date: Date.new(2024, 1, 15), end_date: Date.new(2024, 1, 20)).to_a
    assert_equal [ @february ], search(start_date: Date.new(2024, 1, 31) + 1).to_a
    assert_equal [ @january ], search(end_date: Date.new(2024, 1, 31)).to_a
    assert_empty search(start_date: Date.new(2024, 3, 1))
  end

  test "never widens the scope it is given" do
    narrowed = @scope.where.not(id: @january.id)

    assert_empty AccountStatement::Search.new(narrowed, filters: { account_id: accounts(:depository).id }).account_statements_scope
  end

  private

    def search(filters)
      AccountStatement::Search.new(@scope, filters: filters).account_statements_scope
    end

    def create_statement(account, content, period_start_on, period_end_on)
      statement = AccountStatement.create_from_upload!(
        family: @family,
        account: account,
        file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: content)
      )
      statement.update!(period_start_on:, period_end_on:)
      statement
    end
end

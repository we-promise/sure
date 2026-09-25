require "test_helper"

class Assistant::Function::ImportStatementTransactionsTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository)
    @function = Assistant::Function::ImportStatementTransactions.new(users(:family_admin))
  end

  test "creates a reviewable import without calling an LLM provider" do
    result = nil

    assert_no_difference "Entry.count" do
      assert_difference "Import.where(type: 'TransactionImport').count", 1 do
        result = @function.call(
          "account_id" => @account.id,
          "filename" => "statement.pdf",
          "transactions" => [
            { "date" => "2026-09-01", "amount" => 125.50, "name" => "Payroll" },
            { "date" => "2026-09-02", "amount" => -12.25, "name" => "Coffee" }
          ]
        )
      end
    end

    assert result[:success]
    import = Import.find(result[:import_id])
    assert_equal 2, import.rows_count
    assert_equal "statement.pdf", result[:filename]
  end

  test "preserves extracted categories when the import is published" do
    result = @function.call(
      "account_id" => @account.id,
      "transactions" => [
        { "date" => "2026-09-01", "amount" => -12.25, "name" => "Codex Coffee", "category" => "Food & Drink" }
      ]
    )
    import = Import.find(result[:import_id])

    import.publish

    transaction = @account.entries.find_by!(name: "Codex Coffee").entryable
    assert_equal categories(:food_and_drink), transaction.category
  end

  test "rejects an account the user cannot write to" do
    function = Assistant::Function::ImportStatementTransactions.new(users(:family_member))
    result = function.call(
      "account_id" => accounts(:other_asset).id,
      "transactions" => [ { "date" => "2026-09-01", "amount" => 1, "name" => "Hidden" } ]
    )

    assert_not result[:success]
    assert_equal "account_not_found", result[:error]
  end
end

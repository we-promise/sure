require "test_helper"

class Assistant::Function::CreateTransactionTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = @family.accounts.first
    @function = Assistant::Function::CreateTransaction.new(@user)
  end

  test "is registered with an idempotent create schema" do
    definition = @function.to_definition

    assert_equal "create_transaction", definition[:name]
    assert_includes Assistant.function_classes, Assistant::Function::CreateTransaction
    assert_equal %w[account_id amount date name nature external_id], definition.dig(:params_schema, :required)
  end

  test "creates an expense on a writable account with annotations" do
    category = categories(:food_and_drink)
    merchant = merchants(:amazon)
    tag = tags(:one)

    assert_difference "@account.entries.count", 1 do
      result = @function.call(
        "account_id" => @account.id,
        "amount" => 62_000,
        "date" => Date.current.iso8601,
        "name" => "Sewerage",
        "nature" => "expense",
        "category_id" => category.id,
        "merchant_id" => merchant.id,
        "tag_ids" => [ tag.id ],
        "notes" => "Created through MCP",
        "external_id" => "telegram:chat:message"
      )

      assert result[:success]
      assert_equal true, result[:created]
      assert_equal @account.id, result.dig(:transaction, :account_id)
      assert_equal "Sewerage", result.dig(:transaction, :name)
    end

    entry = @account.entries.find_by!(source: "mcp", external_id: "telegram:chat:message")
    assert_equal 62_000, entry.amount
    assert_equal category, entry.transaction.category
    assert_equal merchant, entry.transaction.merchant
    assert_equal [ tag.id ], entry.transaction.tag_ids
    assert_equal "Created through MCP", entry.notes
  end

  test "returns the existing transaction when the same payload is retried" do
    params = required_params("external_id" => "retry-key")
    first_result = @function.call(params)

    assert_no_difference "@account.entries.count" do
      second_result = @function.call(params)

      assert second_result[:success]
      assert_equal false, second_result[:created]
      assert_equal first_result.dig(:transaction, :id), second_result.dig(:transaction, :id)
    end
  end

  test "rejects an idempotency key reused with a different payload" do
    params = required_params("external_id" => "conflict-key")
    first_result = @function.call(params)

    assert_no_difference "@account.entries.count" do
      second_result = @function.call(params.merge("amount" => 26))

      assert first_result[:success]
      assert_equal false, second_result[:success]
      assert_equal "idempotency_conflict", second_result[:error]
      assert_equal 25, @account.entries.find_by!(source: "mcp", external_id: "conflict-key").amount
    end
  end

  test "creates income with a negative stored amount" do
    result = @function.call(required_params("nature" => "income", "external_id" => "income-key"))

    assert result[:success]
    assert_equal "income", result.dig(:transaction, :nature)
    assert_equal(-25, @account.entries.find_by!(external_id: "income-key", source: "mcp").amount)
  end

  test "rejects accounts the user cannot write to" do
    read_only_account = accounts(:credit_card)
    function = Assistant::Function::CreateTransaction.new(users(:family_member))

    assert_no_difference "read_only_account.entries.count" do
      result = function.call(required_params("account_id" => read_only_account.id, "external_id" => "forbidden-key"))

      assert_equal false, result[:success]
      assert_equal "account_not_found", result[:error]
    end
  end

  test "allows full-control collaborators to create transactions" do
    shared_account = accounts(:depository)
    function = Assistant::Function::CreateTransaction.new(users(:family_member))

    assert_difference "shared_account.entries.count", 1 do
      result = function.call(required_params("account_id" => shared_account.id, "external_id" => "shared-key"))
      assert result[:success]
    end
  end

  test "rejects category merchant and tag ids outside the family" do
    other_family = families(:empty)
    category = other_family.categories.create!(name: "Other", color: "#e99537", lucide_icon: "tag")
    merchant = FamilyMerchant.create!(family: other_family, name: "Other merchant", color: "#e99537")
    tag = other_family.tags.create!(name: "Other tag", color: "#e99537")

    category_result = @function.call(required_params("category_id" => category.id, "external_id" => "foreign-category"))
    merchant_result = @function.call(required_params("merchant_id" => merchant.id, "external_id" => "foreign-merchant"))
    tags_result = @function.call(required_params("tag_ids" => [ tag.id ], "external_id" => "foreign-tags"))

    assert_equal "invalid_category", category_result[:error]
    assert_equal "invalid_merchant", merchant_result[:error]
    assert_equal "invalid_tags", tags_result[:error]
  end

  test "requires a non-blank external idempotency key" do
    assert_no_difference "@account.entries.count" do
      result = @function.call(required_params("external_id" => "  "))

      assert_equal false, result[:success]
      assert_equal "external_id_required", result[:error]
    end
  end

  test "rejects malformed amount date and nature without creating entries" do
    assert_no_difference "@account.entries.count" do
      amount_result = @function.call(required_params("amount" => 0, "external_id" => "bad-amount"))
      date_result = @function.call(required_params("date" => "tomorrow", "external_id" => "bad-date"))
      nature_result = @function.call(required_params("nature" => "transfer", "external_id" => "bad-nature"))

      assert_equal "invalid_amount", amount_result[:error]
      assert_equal "invalid_parameters", date_result[:error]
      assert_equal "invalid_nature", nature_result[:error]
    end
  end

  test "rejects an idempotency collision with a non-transaction entry" do
    @account.entries.create!(
      name: "Existing valuation",
      amount: 100,
      currency: @account.currency,
      date: Date.current,
      external_id: "non-transaction-key",
      source: "mcp",
      entryable: Valuation.new
    )

    assert_no_difference "@account.entries.count" do
      result = @function.call(required_params("external_id" => "non-transaction-key"))

      assert_equal false, result[:success]
      assert_equal "idempotency_conflict", result[:error]
    end
  end

  private
    def required_params(overrides = {})
      {
        "account_id" => @account.id,
        "amount" => 25,
        "date" => Date.current.iso8601,
        "name" => "Test transaction",
        "nature" => "expense",
        "external_id" => "test-key"
      }.merge(overrides)
    end
end

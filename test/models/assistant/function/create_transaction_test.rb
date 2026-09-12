require "test_helper"

class Assistant::Function::CreateTransactionTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
    @function = Assistant::Function::CreateTransaction.new(@user)
  end

  test "creates an expense transaction" do
    result = @function.call(
      "account_id" => @account.id,
      "date" => "2026-09-11",
      "amount" => 2194.15,
      "type" => "expense",
      "name" => "Roche"
    )

    assert_equal true, result[:success]
    assert_equal true, result[:created]

    entry = Entry.find_by(name: "Roche", account: @account, date: Date.new(2026, 9, 11))
    assert entry
    assert_equal "Transaction", entry.entryable_type
    assert_equal BigDecimal("2194.15"), entry.amount
    assert_equal "expense", entry.classification
  end

  test "creates an income transaction with negative amount" do
    result = @function.call(
      "account_id" => @account.id,
      "date" => "2026-09-03",
      "amount" => 15.00,
      "type" => "income",
      "name" => "Welcome Gift"
    )

    assert_equal true, result[:success]
    assert_equal true, result[:created]

    entry = Entry.find_by(name: "Welcome Gift", account: @account, date: Date.new(2026, 9, 3))
    assert entry
    assert_equal BigDecimal("-15.00"), entry.amount
    assert_equal "income", entry.classification
  end

  test "creates a transaction with a zero amount" do
    result = @function.call(
      "account_id" => @account.id,
      "date" => "2026-09-05",
      "amount" => 0.00,
      "type" => "expense",
      "name" => "AT&T"
    )

    assert_equal true, result[:success]
    assert_equal true, result[:created]

    entry = Entry.find_by(name: "AT&T", account: @account, date: Date.new(2026, 9, 5))
    assert entry
    assert_equal BigDecimal("0.00"), entry.amount
  end

  test "reports created with a warning when the post-create sync fails to enqueue" do
    # The transaction is committed by entry.save BEFORE sync_account_later runs.
    # A failure to enqueue the balance-sync job (e.g. an unavailable job
    # backend) must NOT be reported as a failed create — otherwise an MCP
    # caller retries without an external_id and creates a duplicate.
    Entry.any_instance.stubs(:sync_account_later).raises(StandardError, "job backend unavailable")

    result = @function.call(
      "account_id" => @account.id,
      "date" => "2026-09-11",
      "amount" => 100.00,
      "type" => "expense",
      "name" => "Sync Failure Case"
    )

    assert_equal true, result[:success]
    assert_equal true, result[:created]
    assert_match(/could not be enqueued/, result[:warning])

    # The transaction was actually persisted despite the sync failure.
    entry = Entry.find_by(name: "Sync Failure Case", account: @account, date: Date.new(2026, 9, 11))
    assert entry
  end

  test "stores amount as-given when no type is provided" do
    result = @function.call(
      "account_id" => @account.id,
      "date" => "2026-09-04",
      "amount" => -28000.00,
      "name" => "SoFi Transfer"
    )

    assert_equal true, result[:success]
    assert_equal true, result[:created]

    entry = Entry.find_by(name: "SoFi Transfer", account: @account, date: Date.new(2026, 9, 4))
    assert entry
    assert_equal BigDecimal("-28000.00"), entry.amount
    assert_equal "income", entry.classification
  end

  test "creates a transaction with category, merchant, and tags" do
    category = categories(:food_and_drink)
    merchant = merchants(:amazon)
    tag = tags(:one)

    result = @function.call(
      "account_id" => @account.id,
      "date" => "2026-09-11",
      "amount" => 42.50,
      "type" => "expense",
      "name" => "Amazon Order",
      "category_id" => category.id,
      "merchant_id" => merchant.id,
      "tag_ids" => [ tag.id ]
    )

    assert_equal true, result[:success]
    assert_equal true, result[:created]

    transaction = Transaction.find(result[:transaction][:id])
    assert_equal category, transaction.category
    assert_equal merchant, transaction.merchant
    assert_equal [ tag.id ], transaction.tag_ids
  end

  test "is idempotent when external_id and source match" do
    first = @function.call(
      "account_id" => @account.id,
      "date" => "2026-09-11",
      "amount" => 100.00,
      "type" => "expense",
      "name" => "Idempotent Test",
      "external_id" => "xmoney-001",
      "source" => "xmoney"
    )
    assert_equal true, first[:success]
    assert_equal true, first[:created]

    second = @function.call(
      "account_id" => @account.id,
      "date" => "2026-09-11",
      "amount" => 100.00,
      "type" => "expense",
      "name" => "Idempotent Test",
      "external_id" => "xmoney-001",
      "source" => "xmoney"
    )
    assert_equal true, second[:success]
    assert_equal false, second[:created]
    assert_equal first[:transaction][:id], second[:transaction][:id]
  end

  test "rejects an account the user cannot write to" do
    other_account = accounts(:other_asset)
    # other_asset is owned by family_admin too, so use a different approach:
    # create a read-only share for family_member on depository
    @account.account_shares.find_by!(user: users(:family_member)).update!(permission: "read_only")
    function = Assistant::Function::CreateTransaction.new(users(:family_member))

    result = function.call(
      "account_id" => @account.id,
      "date" => "2026-09-11",
      "amount" => 10.00,
      "type" => "expense",
      "name" => "Should Fail"
    )

    assert_equal false, result[:success]
    assert_equal "account_not_found", result[:error]
  end

  test "rejects an invalid date" do
    result = @function.call(
      "account_id" => @account.id,
      "date" => "not-a-date",
      "amount" => 10.00,
      "type" => "expense",
      "name" => "Bad Date"
    )

    assert_equal false, result[:success]
    assert_equal "invalid_date", result[:error]
  end

  test "rejects an invalid amount" do
    result = @function.call(
      "account_id" => @account.id,
      "date" => "2026-09-11",
      "amount" => "abc",
      "type" => "expense",
      "name" => "Bad Amount"
    )

    assert_equal false, result[:success]
    assert_equal "invalid_amount", result[:error]
  end

  test "rejects an empty name" do
    result = @function.call(
      "account_id" => @account.id,
      "date" => "2026-09-11",
      "amount" => 10.00,
      "type" => "expense",
      "name" => "   "
    )

    assert_equal false, result[:success]
    assert_equal "invalid_name", result[:error]
  end

  test "rejects a category outside the family" do
    other_category = Category.create!(
      family: families(:empty),
      name: "Other",
      color: "#e99537",
      lucide_icon: "tag"
    )

    result = @function.call(
      "account_id" => @account.id,
      "date" => "2026-09-11",
      "amount" => 10.00,
      "type" => "expense",
      "name" => "Bad Category",
      "category_id" => other_category.id
    )

    assert_equal false, result[:success]
    assert_equal "invalid_category", result[:error]
  end

  test "rejects a non-UUID account_id" do
    result = @function.call(
      "account_id" => "not-a-uuid",
      "date" => "2026-09-11",
      "amount" => 10.00,
      "type" => "expense",
      "name" => "Bad Account"
    )

    assert_equal false, result[:success]
    assert_equal "account_not_found", result[:error]
  end

  test "marks user_modified when requested" do
    result = @function.call(
      "account_id" => @account.id,
      "date" => "2026-09-11",
      "amount" => 10.00,
      "type" => "expense",
      "name" => "User Modified",
      "user_modified" => true
    )

    assert_equal true, result[:success]
    assert_equal true, result[:created]

    entry = Entry.find_by(name: "User Modified", account: @account)
    assert entry.user_modified?
  end
end

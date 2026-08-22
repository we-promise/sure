# frozen_string_literal: true

require "test_helper"

class Api::V1::TransactionsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = @family.accounts.first
    @transaction = @family.transactions.first

    # Destroy existing active API keys to avoid validation errors
    @user.api_keys.active.destroy_all

    # Create fresh API keys instead of using fixtures to avoid parallel test conflicts (rate limiting in test)
    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "test_rw_#{SecureRandom.hex(8)}"
    )

    @read_only_api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Only Key",
      scopes: [ "read" ],
      display_key: "test_ro_#{SecureRandom.hex(8)}",
      source: "mobile"  # Use different source to allow multiple keys
    )

    # Clear any existing rate limit data
    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_only_api_key.id}")
  end

  # INDEX action tests
  test "should get index with valid API key" do
    get api_v1_transactions_url, headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert response_data.key?("transactions")
    assert response_data.key?("pagination")

    # Agent-friendly numeric fields (validate type + sign invariants)
    first = response_data["transactions"].first
    assert_amount_cents_fields(first)
    assert response_data["pagination"].key?("page")
    assert response_data["pagination"].key?("per_page")
    assert response_data["pagination"].key?("total_count")
    assert response_data["pagination"].key?("total_pages")
  end

  test "index avoids per-transaction transfer queries" do
    from_account = @family.accounts.first
    to_account = @family.accounts.second || @family.accounts.create!(
      name: "Second Account",
      balance: 0,
      currency: @family.currency,
      accountable: Depository.new
    )

    create_transfer(from_account: from_account, to_account: to_account, amount: 10)
    baseline_queries = count_db_queries do
      get api_v1_transactions_url, params: { per_page: 200 }, headers: api_headers(@api_key)
      assert_response :success
    end

    5.times { create_transfer(from_account: from_account, to_account: to_account, amount: 10) }
    expanded_queries = count_db_queries do
      get api_v1_transactions_url, params: { per_page: 200 }, headers: api_headers(@api_key)
      assert_response :success
    end

    assert_equal baseline_queries, expanded_queries
  end

  test "should get index with read-only API key" do
    get api_v1_transactions_url, headers: api_headers(@read_only_api_key)
    assert_response :success
  end

  test "should filter transactions by account_id" do
    get api_v1_transactions_url, params: { account_id: @account.id }, headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    response_data["transactions"].each do |transaction|
      assert_equal @account.id, transaction["account"]["id"]
    end
  end

  test "should include disabled account transactions in index history" do
    disabled_transaction = create_disabled_account_transaction(name: "Closed Account Grocery")

    get api_v1_transactions_url, headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    transaction_ids = response_data["transactions"].map { |transaction| transaction["id"] }
    assert_includes transaction_ids, disabled_transaction.id
  end

  test "should exclude pending deletion account transactions from index history" do
    pending_deletion_transaction = create_account_transaction(
      status: "pending_deletion",
      name: "Pending Delete Account Grocery"
    )

    get api_v1_transactions_url, headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    transaction_ids = response_data["transactions"].map { |transaction| transaction["id"] }
    assert_not_includes transaction_ids, pending_deletion_transaction.id
  end

  test "should filter disabled account transactions by account_id" do
    disabled_transaction = create_disabled_account_transaction(name: "Closed Account Filter")
    disabled_account = disabled_transaction.entry.account

    get api_v1_transactions_url,
        params: { account_id: disabled_account.id },
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert_equal [ disabled_transaction.id ], response_data["transactions"].map { |transaction| transaction["id"] }
  end

  test "should filter transactions by date range" do
    start_date = 1.month.ago.to_date
    end_date = Date.current

    get api_v1_transactions_url,
        params: { start_date: start_date, end_date: end_date },
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    response_data["transactions"].each do |transaction|
      transaction_date = Date.parse(transaction["date"])
      assert transaction_date >= start_date
      assert transaction_date <= end_date
    end
  end

  test "should filter transactions by tag_ids without error" do
    tag_one = tags(:one)
    tag_two = tags(:two)
    tagged_entry = @account.entries.create!(
      name: "Tagged Transaction",
      amount: 12.34,
      currency: "USD",
      date: Date.current,
      entryable: Transaction.new(tags: [ tag_one, tag_two ])
    )

    untagged_entry = @account.entries.create!(
      name: "Untagged Transaction",
      amount: 12.34,
      currency: "USD",
      date: Date.current,
      entryable: Transaction.new
    )

    get api_v1_transactions_url,
        params: { tag_ids: [ tag_one.id, tag_two.id ], per_page: 200 },
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    transaction_ids = response_data["transactions"].map { |t| t["id"] }
    assert_equal 1, transaction_ids.count(tagged_entry.transaction.id)
    assert_includes transaction_ids, tagged_entry.transaction.id
    assert_not_includes transaction_ids, untagged_entry.transaction.id
  end

  test "should filter disabled account transactions by date range" do
    disabled_transaction = create_disabled_account_transaction(
      name: "Closed Account Date Range",
      date: Date.current - 3.days
    )

    get api_v1_transactions_url,
        params: { start_date: Date.current - 4.days, end_date: Date.current - 2.days },
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    transaction_ids = response_data["transactions"].map { |transaction| transaction["id"] }
    assert_includes transaction_ids, disabled_transaction.id
  end

  test "should search transactions" do
    # Create a transaction with a specific name for testing
    entry = @account.entries.create!(
      name: "Test Coffee Purchase",
      amount: 5.50,
      currency: "USD",
      date: Date.current,
      entryable: Transaction.new
    )

    get api_v1_transactions_url,
        params: { search: "Coffee" },
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    found_transaction = response_data["transactions"].find { |t| t["id"] == entry.transaction.id }
    assert_not_nil found_transaction, "Should find the coffee transaction"
  end

  test "should search disabled account transactions" do
    disabled_transaction = create_disabled_account_transaction(name: "Closed Account Coffee")

    get api_v1_transactions_url,
        params: { search: "Closed Account Coffee" },
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    found_transaction = response_data["transactions"].find { |transaction| transaction["id"] == disabled_transaction.id }
    assert_not_nil found_transaction, "Should find disabled account transactions in global history search"
  end

  test "should paginate transactions" do
    get api_v1_transactions_url,
        params: { page: 1, per_page: 5 },
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert response_data["transactions"].size <= 5
    assert_equal 1, response_data["pagination"]["page"]
    assert_equal 5, response_data["pagination"]["per_page"]
  end

  test "should reject index request without API key" do
    get api_v1_transactions_url
    assert_response :unauthorized
  end

  test "should reject index request with invalid API key" do
    get api_v1_transactions_url, headers: { "X-Api-Key" => "invalid-key" }
    assert_response :unauthorized
  end

  # SHOW action tests
  test "should show transaction with valid API key" do
    get api_v1_transaction_url(@transaction), headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert_equal @transaction.id, response_data["id"]
    assert response_data.key?("name")
    assert response_data.key?("amount")
    assert_amount_cents_fields(response_data)
    assert response_data.key?("date")
    assert response_data.key?("account")
  end

  test "should show transaction with read-only API key" do
    get api_v1_transaction_url(@transaction), headers: api_headers(@read_only_api_key)
    assert_response :success
  end

  test "should show disabled account transaction" do
    disabled_transaction = create_disabled_account_transaction(name: "Closed Account Show")

    get api_v1_transaction_url(disabled_transaction), headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert_equal disabled_transaction.id, response_data["id"]
    assert_equal disabled_transaction.entry.account_id, response_data["account"]["id"]
  end

  test "should return 404 for valid missing transaction id" do
    get api_v1_transaction_url(SecureRandom.uuid), headers: api_headers(@api_key)
    assert_response :not_found

    response_data = JSON.parse(response.body)
    assert_equal "not_found", response_data["error"]
    assert_equal "Transaction not found", response_data["message"]
  end

  test "should return 404 for malformed id" do
    get api_v1_transaction_url(999999), headers: api_headers(@api_key)
    assert_response :not_found

    response_data = JSON.parse(response.body)
    assert_equal "not_found", response_data["error"]
    assert_equal "Transaction not found", response_data["message"]
  end

  test "should reject show request without API key" do
    get api_v1_transaction_url(@transaction)
    assert_response :unauthorized
  end

  # CREATE action tests
  test "should create transaction with valid parameters" do
    transaction_params = {
      transaction: {
        account_id: @account.id,
        name: "Test Transaction",
        amount: 25.00,
        date: Date.current,
        currency: "USD",
        nature: "expense"
      }
    }

    assert_difference("@account.entries.count", 1) do
      post api_v1_transactions_url,
           params: transaction_params,
           headers: api_headers(@api_key)
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    assert_equal "Test Transaction", response_data["name"]
    assert_equal @account.id, response_data["account"]["id"]
  end

  test "should create transaction with external idempotency key" do
    transaction_params = {
      transaction: {
        account_id: @account.id,
        name: "Imported Transaction",
        amount: 25.00,
        date: Date.current,
        currency: "USD",
        nature: "expense",
        external_id: "import-txn-1",
        source: "external_import"
      }
    }

    assert_difference("@account.entries.count", 1) do
      post api_v1_transactions_url,
           params: transaction_params,
           headers: api_headers(@api_key)
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    assert_equal "import-txn-1", response_data["external_id"]
    assert_equal "external_import", response_data["source"]

    entry = @account.entries.find_by!(external_id: "import-txn-1", source: "external_import")
    assert_equal response_data["id"], entry.transaction.id
  end

  test "should use default source when external_id provided without source" do
    transaction_params = {
      transaction: {
        account_id: @account.id,
        name: "Imported Transaction",
        amount: 25.00,
        date: Date.current,
        currency: "USD",
        nature: "expense",
        external_id: "default-source-test"
      }
    }

    assert_difference("@account.entries.count", 1) do
      post api_v1_transactions_url,
           params: transaction_params,
           headers: api_headers(@api_key)
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    entry = @account.entries.find_by!(external_id: "default-source-test")
    assert_equal "api", entry.source
    assert_equal "api", response_data["source"]

    assert_no_difference("@account.entries.count") do
      post api_v1_transactions_url,
           params: transaction_params.deep_merge(transaction: { name: "Changed Name" }),
           headers: api_headers(@api_key)
    end

    assert_response :ok
  end

  test "should reject source without external idempotency key" do
    transaction_params = {
      transaction: {
        account_id: @account.id,
        name: "Imported Transaction",
        amount: 25.00,
        date: Date.current,
        currency: "USD",
        nature: "expense",
        source: "external_import"
      }
    }

    assert_no_difference("@account.entries.count") do
      post api_v1_transactions_url,
           params: transaction_params,
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_equal "Source requires external_id", response_data["message"]
    assert_equal [ "Source requires external_id" ], response_data["errors"]
  end

  test "should return existing transaction for duplicate external idempotency key" do
    transaction_params = {
      transaction: {
        account_id: @account.id,
        name: "Imported Transaction",
        amount: 25.00,
        date: Date.current,
        currency: "USD",
        nature: "expense",
        external_id: "import-txn-2",
        source: "external_import"
      }
    }

    post api_v1_transactions_url,
         params: transaction_params,
         headers: api_headers(@api_key)
    assert_response :created
    created_data = JSON.parse(response.body)

    assert_no_difference("@account.entries.count") do
      post api_v1_transactions_url,
           params: transaction_params.deep_merge(transaction: { name: "Changed Name" }),
           headers: api_headers(@api_key)
    end

    assert_response :ok
    response_data = JSON.parse(response.body)
    assert_equal created_data["id"], response_data["id"]
    assert_equal "Imported Transaction", response_data["name"]
  end

  test "should scope external idempotency keys to account" do
    other_account = @family.accounts.create!(
      name: "Other API Account",
      accountable: Depository.new,
      balance: 0,
      currency: "USD"
    )
    transaction_params = {
      transaction: {
        name: "Imported Transaction",
        amount: 25.00,
        date: Date.current,
        currency: "USD",
        nature: "expense",
        external_id: "shared-import-txn",
        source: "external_import"
      }
    }

    assert_difference("Entry.count", 2) do
      post api_v1_transactions_url,
           params: transaction_params.deep_merge(transaction: { account_id: @account.id }),
           headers: api_headers(@api_key)
      assert_response :created

      post api_v1_transactions_url,
           params: transaction_params.deep_merge(transaction: { account_id: other_account.id }),
           headers: api_headers(@api_key)
      assert_response :created
    end
  end

  test "should scope external idempotency keys to source" do
    transaction_params = {
      transaction: {
        account_id: @account.id,
        name: "Imported Transaction",
        amount: 25.00,
        date: Date.current,
        currency: "USD",
        nature: "expense",
        external_id: "shared-source-txn",
        source: "external_import"
      }
    }

    assert_difference("Entry.count", 2) do
      post api_v1_transactions_url,
           params: transaction_params,
           headers: api_headers(@api_key)
      assert_response :created

      post api_v1_transactions_url,
           params: transaction_params.deep_merge(transaction: { source: "other_import" }),
           headers: api_headers(@api_key)
      assert_response :created
    end

    @account.entries.find_by!(external_id: "shared-source-txn", source: "external_import")
    @account.entries.find_by!(external_id: "shared-source-txn", source: "other_import")
  end

  test "should reject external idempotency key collision with non-transaction entry" do
    @account.entries.create!(
      name: "Existing valuation",
      amount: 100,
      currency: "USD",
      date: Date.current,
      external_id: "import-non-transaction",
      source: "external_import",
      entryable: Valuation.new
    )

    post api_v1_transactions_url,
         params: {
           transaction: {
             account_id: @account.id,
             name: "Imported Transaction",
             amount: 25.00,
             date: Date.current - 1.day,
             currency: "USD",
             nature: "expense",
             external_id: "import-non-transaction",
             source: "external_import"
           }
         },
         headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "should reject create with read-only API key" do
    transaction_params = {
      transaction: {
        account_id: @account.id,
        name: "Test Transaction",
        amount: 25.00,
        date: Date.current
      }
    }

    post api_v1_transactions_url,
         params: transaction_params,
         headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "should reject create with invalid parameters" do
    transaction_params = {
      transaction: {
        # Missing required fields
        name: "Test Transaction"
      }
    }

    post api_v1_transactions_url,
         params: transaction_params,
         headers: api_headers(@api_key)
    assert_response :unprocessable_entity
  end

  test "should reject invalid date on create" do
    transaction_params = {
      transaction: {
        account_id: @account.id,
        name: "Invalid Date Transaction",
        amount: 25.00,
        date: "not-a-date",
        currency: "USD",
        nature: "expense"
      }
    }

    assert_no_difference("@account.entries.count") do
      post api_v1_transactions_url,
           params: transaction_params,
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_equal "Transaction could not be created", response_data["message"]
    assert response_data["errors"].any? { |error| error.match?(/Date/) }
  end

  test "should reject create without API key" do
    post api_v1_transactions_url, params: { transaction: { name: "Test" } }
    assert_response :unauthorized
  end

  # UPDATE action tests
  test "should update transaction with valid parameters" do
    update_params = {
      transaction: {
        name: "Updated Transaction Name",
        amount: 30.00
      }
    }

    put api_v1_transaction_url(@transaction),
        params: update_params,
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert_equal "Updated Transaction Name", response_data["name"]
  end

  test "should reject update with read-only API key" do
    update_params = {
      transaction: {
        name: "Updated Transaction Name"
      }
    }

    put api_v1_transaction_url(@transaction),
        params: update_params,
        headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "should reject update for non-existent transaction" do
    put api_v1_transaction_url(999999),
        params: { transaction: { name: "Test" } },
        headers: api_headers(@api_key)
    assert_response :not_found
  end

  test "should reject update without API key" do
    put api_v1_transaction_url(@transaction), params: { transaction: { name: "Test" } }
    assert_response :unauthorized
  end

  test "should preserve tags when tag_ids not provided in update" do
    # Set up transaction with existing tags
    original_tags = [ Tag.first, Tag.second ]
    @transaction.tags = original_tags
    @transaction.save!

    # Update only the name, without providing tag_ids
    update_params = {
      transaction: {
        name: "Updated Name Only"
      }
    }

    put api_v1_transaction_url(@transaction),
        params: update_params,
        headers: api_headers(@api_key)
    assert_response :success

    @transaction.reload
    assert_equal "Updated Name Only", @transaction.entry.name
    # Tags should be preserved since tag_ids was not in the request
    assert_equal original_tags.map(&:id).sort, @transaction.tag_ids.sort
  end

  test "should clear tags when empty tag_ids explicitly provided in update" do
    # Set up transaction with existing tags
    @transaction.tags = [ Tag.first, Tag.second ]
    @transaction.save!

    # Explicitly provide empty tag_ids to clear tags
    update_params = {
      transaction: {
        name: "Updated Name",
        tag_ids: []
      }
    }

    put api_v1_transaction_url(@transaction),
        params: update_params,
        headers: api_headers(@api_key)
    assert_response :success

    @transaction.reload
    # Tags should be cleared since tag_ids was explicitly provided as empty
    assert_empty @transaction.tags
  end

  test "should update tags when tag_ids explicitly provided in update" do
    # Set up transaction with one tag
    @transaction.tags = [ Tag.first ]
    @transaction.save!

    new_tags = [ Tag.second ]

    update_params = {
      transaction: {
        tag_ids: new_tags.map(&:id)
      }
    }

    put api_v1_transaction_url(@transaction),
        params: update_params,
        headers: api_headers(@api_key)
    assert_response :success

    @transaction.reload
    assert_equal new_tags.map(&:id), @transaction.tag_ids
  end

  # DESTROY action tests
  test "should destroy transaction" do
  entry_to_delete = @account.entries.create!(
    name: "Transaction to Delete",
    amount: 10.00,
    currency: "USD",
    date: Date.current,
    entryable: Transaction.new
  )
  transaction_to_delete = entry_to_delete.transaction

  assert_difference("@account.entries.count", -1) do
    delete api_v1_transaction_url(transaction_to_delete), headers: api_headers(@api_key)
  end

  assert_response :success
  response_data = JSON.parse(response.body)
  assert response_data.key?("message")
end

  test "should reject destroy with read-only API key" do
    delete api_v1_transaction_url(@transaction), headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "should reject destroy for non-existent transaction" do
    delete api_v1_transaction_url(999999), headers: api_headers(@api_key)
    assert_response :not_found
  end

  test "should reject destroy without API key" do
    delete api_v1_transaction_url(@transaction)
    assert_response :unauthorized
  end

  # JSON structure tests
  test "transaction JSON should have expected structure" do
    get api_v1_transaction_url(@transaction), headers: api_headers(@api_key)
    assert_response :success

    transaction_data = JSON.parse(response.body)

    # Basic fields
    assert transaction_data.key?("id")
    assert transaction_data.key?("date")
    assert transaction_data.key?("amount")
    assert transaction_data.key?("currency")
    assert transaction_data.key?("name")
    assert transaction_data.key?("classification")
    assert transaction_data.key?("created_at")
    assert transaction_data.key?("updated_at")

    # Account information
    assert transaction_data.key?("account")
    assert transaction_data["account"].key?("id")
    assert transaction_data["account"].key?("name")
    assert transaction_data["account"].key?("account_type")

    # Optional fields should be present (even if nil)
    assert transaction_data.key?("category")
    assert transaction_data.key?("merchant")
    assert transaction_data.key?("tags")
    assert transaction_data.key?("transfer")
    assert transaction_data.key?("notes")
  end

  test "transactions with transfers should include transfer information" do
    transfer = create_transfer_between_accounts

    get api_v1_transaction_url(transfer.inflow_transaction), headers: api_headers(@api_key)
    assert_response :success

    transaction_data = JSON.parse(response.body)
    assert_not_nil transaction_data["transfer"]
    assert transaction_data["transfer"].key?("id")
    assert transaction_data["transfer"].key?("amount")
    assert transaction_data["transfer"].key?("currency")
    assert transaction_data["transfer"].key?("other_account")
  end

  test "index renders transfer rows without per-transfer transaction lookups" do
    transfer = create_transfer_between_accounts

    queries = capture_sql_queries do
      get api_v1_transactions_url,
          params: { per_page: 100 },
          headers: api_headers(@api_key)
    end

    assert_response :success

    response_data = JSON.parse(response.body)
    transfer_transaction_ids = [ transfer.inflow_transaction_id, transfer.outflow_transaction_id ]
    transfer_rows = response_data["transactions"].select { |transaction| transfer_transaction_ids.include?(transaction["id"]) }

    assert_equal 2, transfer_rows.size
    assert transfer_rows.all? { |transaction| transaction["transfer"].present? }
    assert_empty queries.grep(/SELECT "transactions"\.\* FROM "transactions" WHERE "transactions"\."id" =/)
    assert_empty queries.grep(/SELECT "entries"\.\* FROM "entries" WHERE "entries"\."id" =/)
    assert_empty queries.grep(/SELECT "accounts"\.\* FROM "accounts" WHERE "accounts"\."id" =/)
  end

  # SPLIT action tests
  test "should split a transaction into categorized parts" do
    entry = create_transaction(account: @account, name: "Grocery Store", amount: 100)
    category = @family.categories.create!(name: "Food", color: "#4CAF50")

    post split_api_v1_transaction_url(entry.transaction),
         params: {
           split: {
             splits: [
               { name: "Groceries", amount: "70", category_id: category.id },
               { name: "Household", amount: "30" }
             ]
           }
         },
         headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert_equal 2, response_data["splits"].size
    assert_equal [ "Groceries", "Household" ], response_data["splits"].map { |s| s["name"] }
    assert_equal "Food", response_data["splits"].first["category"]["name"]
    assert_nil response_data["splits"].second["category"]

    entry.reload
    assert entry.split_parent?
    assert entry.excluded?
    assert_equal 2, entry.child_entries.count
    by_name = entry.child_entries.index_by(&:name)
    assert_equal 70, by_name["Groceries"].amount.to_i
    assert_equal 30, by_name["Household"].amount.to_i
  end

  test "should expose transaction ids for split children and parent" do
    entry = create_transaction(account: @account, name: "Grocery Store", amount: 100)

    post split_api_v1_transaction_url(entry.transaction),
         params: {
           split: {
             splits: [
               { name: "Groceries", amount: "70" },
               { name: "Household", amount: "30" }
             ]
           }
         },
         headers: api_headers(@api_key)
    assert_response :success

    entry.reload
    response_data = JSON.parse(response.body)
    by_name = entry.child_entries.index_by(&:name)
    response_data["splits"].each do |split|
      assert_equal by_name.fetch(split["name"]).transaction.id, split["id"]
    end

    child = entry.child_entries.first
    get api_v1_transaction_url(child.transaction), headers: api_headers(@api_key)
    assert_response :success
    child_data = JSON.parse(response.body)
    assert_equal entry.transaction.id, child_data["parent_id"]
  end

  test "should reject split when splits key is missing" do
    entry = create_transaction(account: @account, name: "Grocery Store", amount: 100)

    post split_api_v1_transaction_url(entry.transaction),
         params: { split: {} },
         headers: api_headers(@api_key)
    assert_response :bad_request

    response_data = JSON.parse(response.body)
    assert_equal "bad_request", response_data["error"]

    entry.reload
    assert_not entry.split_parent?
  end

  test "should reject split request without API key" do
    entry = create_transaction(account: @account, name: "Grocery Store", amount: 100)

    post split_api_v1_transaction_url(entry.transaction),
         params: { split: { splits: [ { name: "Part 1", amount: "100" } ] } }
    assert_response :unauthorized
  end

  test "should reject unsplit request without API key" do
    entry = create_transaction(account: @account, name: "Grocery Store", amount: 100)
    entry.split!([ { name: "Part 1", amount: 100 } ])

    delete split_api_v1_transaction_url(entry.transaction)
    assert_response :unauthorized
  end

  test "should reject split with malformed split parameter shapes" do
    entry = create_transaction(account: @account, name: "Grocery Store", amount: 100)

    [
      { split: "not-an-object" },
      { split: { splits: "not-an-array" } },
      { split: { splits: [ "not-an-object" ] } },
      { split: { splits: [ { name: "Part 1", amount: [ 100 ] } ] } },
      { split: { splits: [ { name: "Part 1", amount: { value: 100 } } ] } },
      { split: { splits: [ { name: "Part 1", amount: "not-a-number" } ] } }
    ].each do |payload|
      post split_api_v1_transaction_url(entry.transaction), params: payload, headers: api_headers(@api_key)
      assert_includes [ 400, 422 ], response.status, "expected 400/422 for #{payload.inspect}"
    end

    entry.reload
    assert_not entry.split_parent?
  end

  test "concurrent split replacements leave only the winning split set" do
    entry = create_transaction(account: @account, name: "Concurrent", amount: 100)

    barrier = Queue.new
    results = Queue.new
    threads = 2.times.map do |i|
      Thread.new do
        session = open_session
        barrier.pop
        session.post split_api_v1_transaction_url(entry.transaction),
                     params: {
                       split: {
                         splits: [
                           { name: "Set #{i} A", amount: 60 },
                           { name: "Set #{i} B", amount: 40 }
                         ]
                       }
                     },
                     headers: api_headers(@api_key)
        results << session.response.status
      end
    end
    threads.each { barrier << true }
    threads.each(&:join)

    assert_equal [ 200, 200 ], [ results.pop, results.pop ].sort

    entry.reload
    children = entry.child_entries.to_a
    assert_equal 2, children.size
    names = children.map(&:name).sort
    assert [ [ "Set 0 A", "Set 0 B" ].sort, [ "Set 1 A", "Set 1 B" ].sort ].include?(names)
  end

  test "should not split a transaction on a read-only shared account" do
    member = users(:family_member)
    member.api_keys.active.destroy_all
    member_key = ApiKey.create!(
      user: member,
      name: "Test Member RW Key",
      scopes: [ "read_write" ],
      display_key: "test_mem_#{SecureRandom.hex(8)}"
    )
    Redis.new.del("api_rate_limit:#{member_key.id}")

    entry = create_transaction(account: accounts(:credit_card), name: "Shared Purchase", amount: 50)

    post split_api_v1_transaction_url(entry.transaction),
         params: { split: { splits: [ { name: "Part 1", amount: "50" } ] } },
         headers: api_headers(member_key)
    assert_response :not_found

    entry.reload
    assert_not entry.split_parent?
  end

  test "should split a transaction on a fully shared account" do
    member = users(:family_member)
    member.api_keys.active.destroy_all
    member_key = ApiKey.create!(
      user: member,
      name: "Test Member RW Key",
      scopes: [ "read_write" ],
      display_key: "test_mem_#{SecureRandom.hex(8)}"
    )
    Redis.new.del("api_rate_limit:#{member_key.id}")

    entry = create_transaction(account: accounts(:depository), name: "Shared Purchase", amount: 50)

    post split_api_v1_transaction_url(entry.transaction),
         params: { split: { splits: [ { name: "Part 1", amount: "50" } ] } },
         headers: api_headers(member_key)
    assert_response :success
  end

  test "index avoids per-child category queries for split transactions" do
    category = @family.categories.create!(name: "Split Food", color: "#4CAF50")

    split_parent = create_transaction(account: @account, name: "Split Me", amount: 200)
    split_parent.split!([
      { name: "Part A", amount: 120, category_id: category.id },
      { name: "Part B", amount: 80, category_id: category.id }
    ])
    baseline_queries = count_db_queries do
      get api_v1_transactions_url, params: { per_page: 200 }, headers: api_headers(@api_key)
      assert_response :success
    end

    3.times do |i|
      parent = create_transaction(account: @account, name: "Split Me #{i}", amount: 300)
      parent.split!([
        { name: "Part C", amount: 100, category_id: category.id },
        { name: "Part D", amount: 200, category_id: category.id }
      ])
    end
    expanded_queries = count_db_queries do
      get api_v1_transactions_url, params: { per_page: 200 }, headers: api_headers(@api_key)
      assert_response :success
    end

    assert_equal baseline_queries, expanded_queries
  end

  test "should split income transaction with negative parts" do
    entry = create_transaction(account: @account, name: "Reimbursement", amount: -100)

    post split_api_v1_transaction_url(entry.transaction),
         params: {
           split: {
             splits: [
               { name: "Part 1", amount: "-60" },
               { name: "Part 2", amount: "-40" }
             ]
           }
         },
         headers: api_headers(@api_key)
    assert_response :success

    entry.reload
    assert_equal 2, entry.child_entries.count
    assert_equal [ -60, -40 ], entry.child_entries.map { |c| c.amount.to_i }.sort
  end

  test "should reject split when parts do not sum to parent amount" do
    entry = create_transaction(account: @account, name: "Grocery Store", amount: 100)

    post split_api_v1_transaction_url(entry.transaction),
         params: {
           split: {
             splits: [
               { name: "Groceries", amount: "50" },
               { name: "Household", amount: "30" }
             ]
           }
         },
         headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]

    entry.reload
    assert_not entry.split_parent?
    assert_not entry.excluded?
  end

  test "should reject split with no split parts" do
    entry = create_transaction(account: @account, name: "Grocery Store", amount: 100)

    post split_api_v1_transaction_url(entry.transaction),
         params: { split: { splits: [] } },
         headers: api_headers(@api_key)
    assert_response :unprocessable_entity
  end

  test "should reject split with missing split parameter" do
    entry = create_transaction(account: @account, name: "Grocery Store", amount: 100)

    post split_api_v1_transaction_url(entry.transaction),
         params: {},
         headers: api_headers(@api_key)
    assert_response :bad_request
  end

  test "should reject split on a transfer transaction" do
    to_account = @family.accounts.second || @family.accounts.create!(
      name: "Second Account",
      balance: 0,
      currency: @family.currency,
      accountable: Depository.new
    )
    transfer = create_transfer(from_account: @account, to_account: to_account, amount: 10)
    transaction = transfer.outflow_transaction

    post split_api_v1_transaction_url(transaction),
         params: {
           split: {
             splits: [ { name: "Part 1", amount: "10" } ]
           }
         },
         headers: api_headers(@api_key)
    assert_response :unprocessable_entity
  end

  test "should replace an existing split on a split parent" do
    entry = create_transaction(account: @account, name: "Grocery Store", amount: 100)
    entry.split!([ { name: "Old 1", amount: 60 }, { name: "Old 2", amount: 40 } ])

    post split_api_v1_transaction_url(entry.transaction),
         params: {
           split: {
             splits: [
               { name: "New 1", amount: "50" },
               { name: "New 2", amount: "30" },
               { name: "New 3", amount: "20" }
             ]
           }
         },
         headers: api_headers(@api_key)
    assert_response :success

    entry.reload
    assert_equal 3, entry.child_entries.count
    assert_equal %w[New\ 1 New\ 2 New\ 3], entry.child_entries.map(&:name).sort
    assert entry.excluded?
  end

  test "should resolve split child to parent when splitting" do
    entry = create_transaction(account: @account, name: "Grocery Store", amount: 100)
    children = entry.split!([ { name: "Part 1", amount: 60 }, { name: "Part 2", amount: 40 } ])

    post split_api_v1_transaction_url(children.first.transaction),
         params: {
           split: {
             splits: [
               { name: "A", amount: "25" },
               { name: "B", amount: "75" }
             ]
           }
         },
         headers: api_headers(@api_key)
    assert_response :success

    entry.reload
    assert_equal 2, entry.child_entries.count
    assert_equal %w[A B], entry.child_entries.map(&:name).sort
  end

  test "should reject split with read-only API key" do
    entry = create_transaction(account: @account, name: "Grocery Store", amount: 100)

    post split_api_v1_transaction_url(entry.transaction),
         params: {
           split: {
             splits: [ { name: "Groceries", amount: "100" } ]
           }
         },
         headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "should return 404 when splitting unknown transaction" do
    post split_api_v1_transaction_url(SecureRandom.uuid),
         params: {
           split: {
             splits: [ { name: "Groceries", amount: "100" } ]
           }
         },
         headers: api_headers(@api_key)
    assert_response :not_found
  end

  # UNSPLIT action tests
  test "should unsplit a transaction and restore parent" do
    entry = create_transaction(account: @account, name: "Grocery Store", amount: 100)
    entry.split!([ { name: "Part 1", amount: 60 }, { name: "Part 2", amount: 40 } ])

    delete split_api_v1_transaction_url(entry.transaction), headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert_empty response_data["splits"]
    assert_nil response_data["parent_id"]

    entry.reload
    assert_not entry.split_parent?
    assert_not entry.excluded?
    assert_empty entry.child_entries
  end

  test "should reject unsplit on a transaction that is not split" do
    entry = create_transaction(account: @account, name: "Grocery Store", amount: 100)

    delete split_api_v1_transaction_url(entry.transaction), headers: api_headers(@api_key)
    assert_response :unprocessable_entity
  end

  test "should resolve split child to parent when unsplitting" do
    entry = create_transaction(account: @account, name: "Grocery Store", amount: 100)
    children = entry.split!([ { name: "Part 1", amount: 60 }, { name: "Part 2", amount: 40 } ])

    delete split_api_v1_transaction_url(children.first.transaction), headers: api_headers(@api_key)
    assert_response :success

    entry.reload
    assert_not entry.split_parent?
    assert_not entry.excluded?
  end

  test "should reject unsplit with read-only API key" do
    entry = create_transaction(account: @account, name: "Grocery Store", amount: 100)
    entry.split!([ { name: "Part 1", amount: 60 }, { name: "Part 2", amount: 40 } ])

    delete split_api_v1_transaction_url(entry.transaction), headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "should include split fields in index response" do
    get api_v1_transactions_url, headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    first = response_data["transactions"].first
    assert first.key?("parent_id")
    assert first.key?("splits")
    assert_kind_of Array, first["splits"]
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end

    def count_db_queries(&block)
      queries = 0
      callback = lambda do |_name, _started, _finished, _unique_id, payload|
        return if payload[:cached]
        return if payload[:name].in?(%w[SCHEMA TRANSACTION])

        queries += 1
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
      queries
    end

    def create_transfer_between_accounts
      from_account = @family.accounts.create!(
        name: "Transfer From Account",
        balance: 1000,
        currency: "USD",
        accountable: Depository.new
      )

      to_account = @family.accounts.create!(
        name: "Transfer To Account",
        balance: 0,
        currency: "USD",
        accountable: Depository.new
      )

      Transfer::Creator.new(
        family: @family,
        source_account_id: from_account.id,
        destination_account_id: to_account.id,
        date: Date.current,
        amount: 100
      ).create
    end

    def capture_sql_queries
      queries = []
      callback = lambda do |_name, _started, _finished, _unique_id, payload|
        next if payload[:cached]
        next if %w[SCHEMA TRANSACTION].include?(payload[:name])

        queries << payload[:sql].squish
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        yield
      end

      queries
    end

    # Validates agent-friendly numeric fields: type, sign invariants
    def assert_amount_cents_fields(txn_json)
      assert txn_json.key?("amount_cents"), "Expected amount_cents field"
      assert txn_json.key?("signed_amount_cents"), "Expected signed_amount_cents field"
      assert_kind_of Integer, txn_json["amount_cents"]
      assert_kind_of Integer, txn_json["signed_amount_cents"]
      assert_operator txn_json["amount_cents"], :>=, 0, "amount_cents must be non-negative"
      assert_equal txn_json["amount_cents"].abs, txn_json["signed_amount_cents"].abs,
                   "Absolute values of amount_cents and signed_amount_cents must match"
      if txn_json["classification"] == "income"
        assert_operator txn_json["signed_amount_cents"], :>=, 0,
                        "income transactions should have non-negative signed_amount_cents"
      else
        assert_operator txn_json["signed_amount_cents"], :<=, 0,
                        "non-income transactions should have non-positive signed_amount_cents"
      end
    end

    def create_disabled_account_transaction(name:, date: Date.current)
      create_account_transaction(status: "disabled", name: name, date: date)
    end

    def create_account_transaction(status:, name:, date: Date.current)
      account = @family.accounts.create!(
        name: "#{status.titleize} Checking #{SecureRandom.hex(4)}",
        balance: 0,
        currency: "USD",
        status: status,
        accountable: Depository.new
      )

      entry = account.entries.create!(
        name: name,
        amount: 12.34,
        currency: "USD",
        date: date,
        entryable: Transaction.new
      )

      entry.transaction
    end
end

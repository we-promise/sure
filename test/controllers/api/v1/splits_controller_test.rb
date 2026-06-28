# frozen_string_literal: true

require "test_helper"

class Api::V1::SplitsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family

    # Fresh, splittable expense transaction (amount is positive for expenses).
    @entry = create_transaction(
      amount: 100,
      name: "Grocery Store",
      account: accounts(:depository)
    )
    @transaction = @entry.transaction

    @user.api_keys.active.destroy_all
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
      source: "mobile"
    )

    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_only_api_key.id}")
  end

  # --- create ---

  test "splits a transaction into children" do
    assert_difference "Entry.count", 2 do
      post api_v1_transaction_split_url(@transaction),
        params: split_payload([
          { name: "Groceries", amount: 70, category_id: categories(:food_and_drink).id },
          { name: "Household", amount: 30 }
        ]),
        headers: api_headers(@api_key)
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal @transaction.id, body["id"]
    assert @entry.reload.split_parent?
    assert @entry.excluded?
    assert_equal %w[Groceries Household], @entry.child_entries.order(:created_at).pluck(:name)
  end

  test "rejects splits that do not sum to the parent amount" do
    assert_no_difference "Entry.count" do
      post api_v1_transaction_split_url(@transaction),
        params: split_payload([
          { name: "Part 1", amount: 60 },
          { name: "Part 2", amount: 20 }
        ]),
        headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "rejects a split missing an amount" do
    assert_no_difference "Entry.count" do
      post api_v1_transaction_split_url(@transaction),
        params: split_payload([ { name: "No amount" } ]),
        headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "rejects splitting an already-split transaction" do
    @entry.split!([ { name: "A", amount: 50 }, { name: "B", amount: 50 } ])

    post api_v1_transaction_split_url(@transaction),
      params: split_payload([ { name: "X", amount: 100 } ]),
      headers: api_headers(@api_key)

    assert_response :unprocessable_entity
  end

  # --- update ---

  test "replaces existing splits" do
    @entry.split!([ { name: "A", amount: 50 }, { name: "B", amount: 50 } ])

    patch api_v1_transaction_split_url(@transaction),
      params: split_payload([
        { name: "Dining", amount: 80, category_id: categories(:food_and_drink).id },
        { name: "Tip", amount: 20 }
      ]),
      headers: api_headers(@api_key)

    assert_response :success
    assert_equal %w[Dining Tip], @entry.reload.child_entries.order(:created_at).pluck(:name)
  end

  test "update rejects a transaction that is not split" do
    patch api_v1_transaction_split_url(@transaction),
      params: split_payload([ { name: "X", amount: 100 } ]),
      headers: api_headers(@api_key)

    assert_response :unprocessable_entity
  end

  test "update resolves a child transaction id to its parent" do
    @entry.split!([ { name: "A", amount: 50 }, { name: "B", amount: 50 } ])
    child_txn = @entry.child_entries.order(:created_at).first.transaction

    patch api_v1_transaction_split_url(child_txn),
      params: split_payload([
        { name: "Dining", amount: 80 },
        { name: "Tip", amount: 20 }
      ]),
      headers: api_headers(@api_key)

    assert_response :success
    assert_equal %w[Dining Tip], @entry.reload.child_entries.order(:created_at).pluck(:name)
  end

  # --- destroy ---

  test "unsplits a transaction" do
    @entry.split!([ { name: "A", amount: 50 }, { name: "B", amount: 50 } ])

    assert_difference "Entry.count", -2 do
      delete api_v1_transaction_split_url(@transaction), headers: api_headers(@api_key)
    end

    assert_response :success
    refute @entry.reload.split_parent?
    refute @entry.excluded?
  end

  test "destroy resolves a child transaction id to its parent" do
    @entry.split!([ { name: "A", amount: 50 }, { name: "B", amount: 50 } ])
    child_txn = @entry.child_entries.order(:created_at).first.transaction

    assert_difference "Entry.count", -2 do
      delete api_v1_transaction_split_url(child_txn), headers: api_headers(@api_key)
    end

    assert_response :success
    refute @entry.reload.split_parent?
  end

  # --- auth / scoping ---

  test "rejects requests without an API key" do
    post api_v1_transaction_split_url(@transaction),
      params: split_payload([ { name: "X", amount: 100 } ])

    assert_response :unauthorized
  end

  test "read-only key cannot create a split" do
    post api_v1_transaction_split_url(@transaction),
      params: split_payload([ { name: "X", amount: 100 } ]),
      headers: api_headers(@read_only_api_key)

    assert_response :forbidden
  end

  test "read-only key cannot update a split" do
    @entry.split!([ { name: "A", amount: 50 }, { name: "B", amount: 50 } ])

    patch api_v1_transaction_split_url(@transaction),
      params: split_payload([ { name: "X", amount: 100 } ]),
      headers: api_headers(@read_only_api_key)

    assert_response :forbidden
  end

  test "read-only key cannot delete a split" do
    @entry.split!([ { name: "A", amount: 50 }, { name: "B", amount: 50 } ])

    delete api_v1_transaction_split_url(@transaction), headers: api_headers(@read_only_api_key)

    assert_response :forbidden
  end

  test "returns 404 for unknown transaction" do
    post api_v1_transaction_split_url(SecureRandom.uuid),
      params: split_payload([ { name: "X", amount: 100 } ]),
      headers: api_headers(@api_key)

    assert_response :not_found
  end

  test "returns 404 for another family's transaction" do
    other_key = ApiKey.create!(
      user: users(:empty),
      name: "Other Family Key",
      scopes: [ "read_write" ],
      display_key: "test_other_#{SecureRandom.hex(8)}"
    )
    Redis.new.del("api_rate_limit:#{other_key.id}")

    post api_v1_transaction_split_url(@transaction),
      params: split_payload([ { name: "X", amount: 100 } ]),
      headers: api_headers(other_key)

    assert_response :not_found
  end

  private

    def split_payload(splits)
      { split: { splits: splits } }
    end

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end

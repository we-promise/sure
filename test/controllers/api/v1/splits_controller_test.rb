# frozen_string_literal: true

require "test_helper"

class Api::V1::SplitsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = @family.accounts.first
    @entry = create_transaction(account: @account, amount: 100, name: "Splittable")
    @transaction = @entry.entryable

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

  def halves
    { split: { splits: [
      { name: "First half",  amount: (@entry.amount / 2).to_s },
      { name: "Second half", amount: (@entry.amount / 2).to_s }
    ] } }
  end

  # CREATE

  test "splits a transaction into children that sum to it" do
    post api_v1_transaction_split_url(@transaction), params: halves, headers: api_headers(@api_key), as: :json
    assert_response :created

    body = JSON.parse(response.body)
    assert_equal @transaction.id, body["transaction_id"]
    assert_equal 2, body["children"].length

    @entry.reload
    assert @entry.split_parent?
    assert @entry.excluded?, "parent is excluded once split"
    assert_equal @entry.amount, @entry.child_entries.sum(:amount)
  end

  test "assigns categories to children" do
    category = @family.categories.first
    params = { split: { splits: [
      { name: "Categorised", amount: (@entry.amount / 2).to_s, category_id: category.id },
      { name: "Plain",       amount: (@entry.amount / 2).to_s }
    ] } }

    post api_v1_transaction_split_url(@transaction), params: params, headers: api_headers(@api_key), as: :json
    assert_response :created

    categories = @entry.reload.child_entries.map { |c| c.entryable.category_id }
    assert_includes categories, category.id
    assert_includes categories, nil
  end

  test "returns 422 when the children do not sum to the parent" do
    params = { split: { splits: [ { name: "Too small", amount: "1.00" } ] } }

    post api_v1_transaction_split_url(@transaction), params: params, headers: api_headers(@api_key), as: :json
    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
    assert_not @entry.reload.split_parent?
  end

  test "returns 422 when splits is empty" do
    post api_v1_transaction_split_url(@transaction), params: { split: { splits: [] } },
         headers: api_headers(@api_key), as: :json
    assert_response :unprocessable_entity
  end

  test "returns 422 when an amount is not numeric" do
    params = { split: { splits: [ { name: "Bad", amount: "not-a-number" } ] } }

    post api_v1_transaction_split_url(@transaction), params: params, headers: api_headers(@api_key), as: :json
    assert_response :unprocessable_entity
  end

  test "returns 422 when the transaction is already split" do
    post api_v1_transaction_split_url(@transaction), params: halves, headers: api_headers(@api_key), as: :json
    assert_response :created

    post api_v1_transaction_split_url(@transaction), params: halves, headers: api_headers(@api_key), as: :json
    assert_response :unprocessable_entity
  end

  # SHOW

  test "shows the children of a split transaction" do
    post api_v1_transaction_split_url(@transaction), params: halves, headers: api_headers(@api_key), as: :json

    get api_v1_transaction_split_url(@transaction), headers: api_headers(@api_key)
    assert_response :success
    assert_equal 2, JSON.parse(response.body)["children"].length
  end

  test "returns 404 showing a transaction that is not split" do
    get api_v1_transaction_split_url(@transaction), headers: api_headers(@api_key)
    assert_response :not_found
  end

  test "resolves a child id to its parent" do
    post api_v1_transaction_split_url(@transaction), params: halves, headers: api_headers(@api_key), as: :json
    child = @entry.reload.child_entries.first

    get api_v1_transaction_split_url(child.entryable), headers: api_headers(@api_key)
    assert_response :success
    assert_equal @transaction.id, JSON.parse(response.body)["transaction_id"]
  end

  # UPDATE

  test "replaces the children" do
    post api_v1_transaction_split_url(@transaction), params: halves, headers: api_headers(@api_key), as: :json

    thirds = { split: { splits: 3.times.map { |i| { name: "Part #{i}", amount: (@entry.amount / 3).round(2).to_s } } } }
    thirds[:split][:splits][0][:amount] = (@entry.amount - (@entry.amount / 3).round(2) * 2).to_s

    patch api_v1_transaction_split_url(@transaction), params: thirds, headers: api_headers(@api_key), as: :json
    assert_response :success
    assert_equal 3, @entry.reload.child_entries.count
    assert_equal @entry.amount, @entry.child_entries.sum(:amount)
  end

  test "returns 404 updating a transaction that is not split" do
    patch api_v1_transaction_split_url(@transaction), params: halves, headers: api_headers(@api_key), as: :json
    assert_response :not_found
  end

  # DESTROY

  test "unsplits a transaction" do
    post api_v1_transaction_split_url(@transaction), params: halves, headers: api_headers(@api_key), as: :json

    delete api_v1_transaction_split_url(@transaction), headers: api_headers(@api_key)
    assert_response :no_content

    @entry.reload
    assert_not @entry.split_parent?
    assert_not @entry.excluded?, "parent is restored when unsplit"
  end

  test "returns 404 unsplitting a transaction that is not split" do
    delete api_v1_transaction_split_url(@transaction), headers: api_headers(@api_key)
    assert_response :not_found
  end

  # AUTH

  test "read-only key cannot split" do
    post api_v1_transaction_split_url(@transaction), params: halves,
         headers: api_headers(@read_only_api_key), as: :json
    assert_response :forbidden
  end

  test "read-only key cannot unsplit" do
    delete api_v1_transaction_split_url(@transaction), headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "read-only key can read a split" do
    post api_v1_transaction_split_url(@transaction), params: halves, headers: api_headers(@api_key), as: :json

    get api_v1_transaction_split_url(@transaction), headers: api_headers(@read_only_api_key)
    assert_response :success
  end

  # Review findings from PR #4117

  test "a read-only share cannot split, even with a read_write key" do
    other = User.create!(family: @family, email: "viewer-#{SecureRandom.hex(4)}@example.com",
                         password: "password123", password_confirmation: "password123", role: "member")
    @account.update!(owner: @user)
    AccountShare.create!(account: @account, user: other, permission: "read_only")
    other.api_keys.active.destroy_all
    key = ApiKey.create!(user: other, name: "Viewer RW", scopes: [ "read_write" ],
                         display_key: "test_v_#{SecureRandom.hex(8)}")
    Redis.new.del("api_rate_limit:#{key.id}")

    post api_v1_transaction_split_url(@transaction), params: halves, headers: api_headers(key), as: :json
    assert_response :forbidden
    assert_not @entry.reload.split_parent?
  end

  test "rejects a category belonging to another family" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", date_format: "%m-%d-%Y")
    foreign = other_family.categories.create!(name: "Foreign", color: "#000000", lucide_icon: "circle")
    params = { split: { splits: [
      { name: "A", amount: (@entry.amount / 2).to_s, category_id: foreign.id },
      { name: "B", amount: (@entry.amount / 2).to_s }
    ] } }

    post api_v1_transaction_split_url(@transaction), params: params, headers: api_headers(@api_key), as: :json
    assert_response :unprocessable_entity
    assert_not @entry.reload.split_parent?
  end

  test "rounds amounts to the stored scale so children sum exactly" do
    params = { split: { splits: [
      { name: "A", amount: "33.33335" },
      { name: "B", amount: "66.66660" }
    ] } }

    post api_v1_transaction_split_url(@transaction), params: params, headers: api_headers(@api_key), as: :json
    assert_response :created
    assert_equal [ BigDecimal("33.3334"), BigDecimal("66.6666") ],
                 @entry.reload.child_entries.order(:name).map(&:amount)
  end

  test "rejects amounts that only sum to the parent before rounding" do
    params = { split: { splits: [
      { name: "A", amount: "33.33335" },
      { name: "B", amount: "66.66665" }
    ] } }

    post api_v1_transaction_split_url(@transaction), params: params, headers: api_headers(@api_key), as: :json
    assert_response :unprocessable_entity
    assert_not @entry.reload.split_parent?
  end

  test "returns 422 when a split element is not an object" do
    [ [ true ], [ nil ], [ "x" ], [ 1 ], [ [ { amount: "100" } ] ] ].each do |splits|
      post api_v1_transaction_split_url(@transaction), params: { split: { splits: splits } },
           headers: api_headers(@api_key), as: :json
      assert_response :unprocessable_entity, "splits: #{splits.inspect}"
      assert_equal "validation_failed", JSON.parse(response.body)["error"]
    end
    assert_not @entry.reload.split_parent?
  end

  test "a split read back and re-sent keeps each child's exclusion and exact amount" do
    params = { split: { splits: [
      { name: "Excluded", amount: "50.0049", excluded: true },
      { name: "Counted",  amount: "49.9951" }
    ] } }
    post api_v1_transaction_split_url(@transaction), params: params, headers: api_headers(@api_key), as: :json
    assert_response :created

    get api_v1_transaction_split_url(@transaction), headers: api_headers(@api_key)
    children = JSON.parse(response.body)["children"]
    assert_equal [ [ "Excluded", "50.0049", true ], [ "Counted", "49.9951", false ] ],
                 children.map { |c| c.values_at("name", "amount_decimal", "excluded") }

    resent = children.map { |c| { name: c["name"] == "Counted" ? "Renamed" : c["name"], amount: c["amount_decimal"], excluded: c["excluded"] } }
    patch api_v1_transaction_split_url(@transaction), params: { split: { splits: resent } },
          headers: api_headers(@api_key), as: :json
    assert_response :success

    assert_equal [ [ "Excluded", BigDecimal("50.0049"), true ], [ "Renamed", BigDecimal("49.9951"), false ] ],
                 @entry.reload.child_entries.order(:name).map { |c| [ c.name, c.amount, c.excluded ] }
  end

  test "returns 422 for amounts too large to store, even when they sum to the parent" do
    # The second is under the limit as sent and only reaches it once rounded.
    [ "1#{"0" * 20}", "999999999999999.99995" ].each do |huge|
      params = { split: { splits: [
        { name: "A", amount: huge },
        { name: "B", amount: "-#{huge}" },
        { name: "C", amount: @entry.amount.to_s }
      ] } }

      post api_v1_transaction_split_url(@transaction), params: params, headers: api_headers(@api_key), as: :json
      assert_response :unprocessable_entity, "amount: #{huge}"
      assert_not @entry.reload.split_parent?
    end
  end

  test "accepts the largest amount the column can store" do
    max = "999999999999999.9999"
    params = { split: { splits: [
      { name: "A", amount: max },
      { name: "B", amount: "-#{max}" },
      { name: "C", amount: @entry.amount.to_s }
    ] } }

    post api_v1_transaction_split_url(@transaction), params: params, headers: api_headers(@api_key), as: :json
    assert_response :created
  end

  test "a rejected replacement leaves the existing split untouched" do
    post api_v1_transaction_split_url(@transaction), params: halves, headers: api_headers(@api_key), as: :json
    assert_response :created
    before = @entry.reload.child_entries.order(:id).pluck(:id, :name, :amount)

    patch api_v1_transaction_split_url(@transaction), params: { split: { splits: [ { name: "Too small", amount: "1.00" } ] } },
          headers: api_headers(@api_key), as: :json
    assert_response :unprocessable_entity

    assert_equal before, @entry.reload.child_entries.order(:id).pluck(:id, :name, :amount)
    assert @entry.excluded?, "parent stays excluded while still split"
  end

  test "showing a split does not query per child" do
    splits = 5.times.map { |i| { name: "Part #{i}", amount: (@entry.amount / 5).to_s } }
    post api_v1_transaction_split_url(@transaction), params: { split: { splits: splits } },
         headers: api_headers(@api_key), as: :json
    assert_response :created

    selects = ->(&block) do
      count = 0
      counter = ->(*, payload) { count += 1 if payload[:sql].start_with?("SELECT") && payload[:name] != "SCHEMA" }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end

    five = selects.call { get api_v1_transaction_split_url(@transaction), headers: api_headers(@api_key) }
    assert_response :success

    patch api_v1_transaction_split_url(@transaction), params: halves, headers: api_headers(@api_key), as: :json
    two = selects.call { get api_v1_transaction_split_url(@transaction), headers: api_headers(@api_key) }

    assert_equal two, five, "query count must not grow with the number of children"
  end

  test "defaults a missing child name to the parent name" do
    params = { split: { splits: [
      { amount: (@entry.amount / 2).to_s },
      { amount: (@entry.amount / 2).to_s }
    ] } }

    post api_v1_transaction_split_url(@transaction), params: params, headers: api_headers(@api_key), as: :json
    assert_response :created
    assert_equal [ @entry.name, @entry.name ], @entry.reload.child_entries.map(&:name)
  end

  test "exposes the exact amount a client needs to replace a split" do
    post api_v1_transaction_split_url(@transaction), params: halves, headers: api_headers(@api_key), as: :json
    body = JSON.parse(response.body)
    assert_equal @entry.amount.to_s, body["amount_decimal"]
    assert body["amount_cents"].is_a?(Integer)
  end

  test "returns 401 without an API key" do
    get api_v1_transaction_split_url(@transaction)
    assert_response :unauthorized
  end

  test "returns 404 for an unknown transaction" do
    get api_v1_transaction_split_url(SecureRandom.uuid), headers: api_headers(@api_key)
    assert_response :not_found
  end

  test "returns 404 for a malformed transaction id" do
    get api_v1_transaction_split_url("not-a-uuid"), headers: api_headers(@api_key)
    assert_response :not_found
  end
end

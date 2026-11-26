# frozen_string_literal: true

require "test_helper"

class Api::V1::TransfersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )

    @account = @family.accounts.create!(
      name: "Transfer Checking",
      accountable: Depository.new,
      balance: 500,
      currency: "USD"
    )
    @destination_account = @family.accounts.create!(
      name: "Transfer Savings",
      accountable: Depository.new,
      balance: 1000,
      currency: "USD"
    )

    outflow = create_transaction(@account, amount: 100, date: Date.parse("2024-01-15"), name: "Transfer to savings")
    inflow = create_transaction(@destination_account, amount: -100, date: Date.parse("2024-01-15"), name: "Transfer from checking")
    @transfer = Transfer.create!(
      outflow_transaction: outflow,
      inflow_transaction: inflow,
      status: "confirmed",
      notes: "Confirmed by user"
    )

    other_family = families(:empty)
    other_account = other_family.accounts.create!(name: "Other Checking", accountable: Depository.new, balance: 0, currency: "USD")
    other_destination = other_family.accounts.create!(name: "Other Savings", accountable: Depository.new, balance: 0, currency: "USD")
    other_outflow = create_transaction(other_account, amount: 50, date: Date.parse("2024-01-15"), name: "Other outflow")
    other_inflow = create_transaction(other_destination, amount: -50, date: Date.parse("2024-01-15"), name: "Other inflow")
    @other_transfer = Transfer.create!(outflow_transaction: other_outflow, inflow_transaction: other_inflow)
  end

  test "lists transfers scoped to the current family" do
    get api_v1_transfers_url, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data.key?("transfers")
    assert response_data.key?("pagination")
    assert_includes response_data["transfers"].map { |transfer| transfer["id"] }, @transfer.id
    assert_not_includes response_data["transfers"].map { |transfer| transfer["id"] }, @other_transfer.id
  end

  test "permits read write scope" do
    read_write_key = ApiKey.create!(
      user: @user,
      name: "Test Read Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "test_read_write_#{SecureRandom.hex(8)}"
    )

    get api_v1_transfers_url, headers: api_headers(read_write_key)

    assert_response :success
  end

  test "shows a transfer" do
    get api_v1_transfer_url(@transfer), headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal @transfer.id, response_data["id"]
    assert_equal "confirmed", response_data["status"]
    assert_equal "Confirmed by user", response_data["notes"]
    assert_equal "Transfer Savings", response_data.dig("inflow_transaction", "account", "name")
    assert_equal "Transfer Checking", response_data.dig("outflow_transaction", "account", "name")
    assert response_data.key?("amount_cents")
    assert_equal "0.0", response_data["source_fee_amount"]
    assert_equal "0.0", response_data["destination_fee_amount"]
    assert response_data.key?("source_fee_currency")
    assert response_data.key?("destination_fee_currency")
  end

  test "returns not found for another family's transfer" do
    get api_v1_transfer_url(@other_transfer), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "returns not found for malformed transfer id" do
    get api_v1_transfer_url("not-a-uuid"), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "filters transfers by status" do
    get api_v1_transfers_url, params: { status: "confirmed" }, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal [ @transfer.id ], response_data["transfers"].map { |transfer| transfer["id"] }
  end

  test "filters transfers by account_id" do
    get api_v1_transfers_url, params: { account_id: @account.id }, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_includes response_data["transfers"].map { |transfer| transfer["id"] }, @transfer.id
  end

  test "rejects malformed account_id filter" do
    get api_v1_transfers_url, params: { account_id: "not-a-uuid" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "rejects invalid status filter" do
    get api_v1_transfers_url, params: { status: "settled" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "rejects invalid date filter" do
    get api_v1_transfers_url, params: { start_date: "01/15/2024" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "filters transfers when either transaction side date matches" do
    matched_outflow = create_transaction(@account, amount: 75, date: Date.parse("2024-02-10"), name: "Dated outflow")
    matched_inflow = create_transaction(@destination_account, amount: -75, date: Date.parse("2024-02-10"), name: "Dated inflow")
    date_matched_transfer = Transfer.create!(outflow_transaction: matched_outflow, inflow_transaction: matched_inflow)

    partial_outflow = create_transaction(@account, amount: 80, date: Date.parse("2024-02-10"), name: "Partial outflow")
    partial_inflow = create_transaction(@destination_account, amount: -80, date: Date.parse("2024-02-12"), name: "Partial inflow")
    partial_date_transfer = Transfer.create!(outflow_transaction: partial_outflow, inflow_transaction: partial_inflow)

    get api_v1_transfers_url,
        params: { start_date: "2024-02-10", end_date: "2024-02-10" },
        headers: api_headers(@api_key)

    assert_response :success
    transfer_ids = JSON.parse(response.body)["transfers"].map { |transfer| transfer["id"] }
    assert_includes transfer_ids, date_matched_transfer.id
    assert_includes transfer_ids, partial_date_transfer.id
    assert_not_includes transfer_ids, @transfer.id
  end

  test "requires authentication" do
    get api_v1_transfers_url

    assert_response :unauthorized
  end

  test "requires read scope" do
    # ApiKey.create! rejects empty scopes; bypass validation to exercise runtime authorization.
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Key",
      scopes: [],
      source: "mobile",
      display_key: "no_read_#{SecureRandom.hex(8)}"
    )
    api_key_without_read.save!(validate: false)

    get api_v1_transfers_url, headers: api_headers(api_key_without_read)

    assert_response :forbidden
  ensure
    api_key_without_read&.destroy
  end

  # CREATE action tests
  test "create requires authentication" do
    post api_v1_transfers_url, params: { transfer: create_params }
    assert_response :unauthorized
  end

  test "create is forbidden for a read-only key" do
    assert_no_difference "Transfer.count" do
      post api_v1_transfers_url, params: { transfer: create_params }, headers: api_headers(@api_key)
    end

    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]
  end

  test "create does not let a guest move money" do
    @user.update!(role: :guest)

    assert_transfer_rejected(status: :forbidden)
  end

  test "create books both legs of a transfer" do
    assert_difference "Transfer.count", 1 do
      post_transfer(amount: "25.50", date: "2024-02-01")
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "confirmed", body["status"]
    assert_equal 2550, body["amount_cents"]
    assert_equal "2024-02-01", body["date"]

    transfer = Transfer.find(body["id"])
    assert_equal @account, transfer.from_account
    assert_equal @destination_account, transfer.to_account
    assert_equal 25.5, transfer.outflow_transaction.entry.amount
    assert_equal(-25.5, transfer.inflow_transaction.entry.amount)
  end

  test "create books fees, tags and a cross-currency rate" do
    tag = tags(:one)

    assert_difference "Transfer.count", 1 do
      post_transfer(to_account_id: euro_account.id, amount: "100", exchange_rate: "0.9", source_fee_amount: "1.5", destination_fee_amount: "0.25", tag_ids: [ tag.id ])
    end

    assert_response :created
    transfer = Transfer.find(JSON.parse(response.body)["id"])
    assert_equal 100, transfer.outflow_transaction.entry.amount
    assert_equal(-90, transfer.inflow_transaction.entry.amount)
    assert_equal 1.5, transfer.derived_source_fee_amount
    assert_equal 0.25, transfer.derived_destination_fee_amount
    assert_equal [ tag.id ], transfer.outflow_transaction.tag_ids
  end

  test "create into a loan is a loan payment" do
    loan = @family.accounts.create!(name: "Transfer Loan", accountable: Loan.new, balance: 5000, currency: "USD")

    post_transfer(to_account_id: loan.id, amount: "200")

    assert_response :created
    assert_equal "loan_payment", JSON.parse(response.body)["transfer_type"]
  end

  test "create defaults the date to today" do
    post api_v1_transfers_url, params: { transfer: create_params.except(:date) }, headers: api_headers(write_api_key)

    assert_response :created
    assert_equal Date.current.iso8601, JSON.parse(response.body)["date"]
  end

  test "create replays an idempotent request instead of duplicating" do
    overrides = { idempotency_key: SecureRandom.uuid }

    post_transfer(**overrides)
    assert_response :created
    first_id = JSON.parse(response.body)["id"]

    assert_no_difference "Transfer.count" do
      post_transfer(**overrides)
    end

    assert_response :ok
    assert_equal first_id, JSON.parse(response.body)["id"]
  end

  test "create replays a cross-currency request whose converted amount has more than 4 decimals" do
    overrides = { to_account_id: euro_account.id, amount: "1", exchange_rate: "0.333333", source_fee_amount: "0.5", idempotency_key: SecureRandom.uuid }

    post_transfer(**overrides)
    assert_response :created

    assert_no_difference "Transfer.count" do
      post_transfer(**overrides)
    end

    assert_response :ok
  end

  test "create answers a reused idempotency key for a different request with 409" do
    key = SecureRandom.uuid
    tag = tags(:one)
    post_transfer(idempotency_key: key, tag_ids: [ tag.id ])
    assert_response :created

    [ { amount: "99" }, { tag_ids: [ tags(:two).id ] } ].each do |changed|
      assert_transfer_rejected(status: :conflict, **{ idempotency_key: key, tag_ids: [ tag.id ] }.merge(changed))
      assert_equal "idempotency_key_conflict", JSON.parse(response.body)["error"]
    end

    post_transfer(idempotency_key: key, tag_ids: [ tag.id ])
    assert_response :ok
  end

  # Values no field of that kind can hold, sent as JSON to every field: an
  # array (which `permit` would drop), false (which reads as blank) and text
  # that is almost right.
  WRONG_SHAPES = {
    uuid: [ [ "x" ], { "a" => "b" }, false, "", "not-a-uuid" ],
    number: [ [ 1 ], false, "12abc", "1_000", 12345678901234.1234, "1e-99999999999999999999", "1e-1000000000" ],
    date: [ "2024-13-45", "2024-1-5", 20240120, [ "2024-01-20" ], false ],
    tag_ids: [ "x", { "a" => "b" }, [ "not-a-uuid" ], [ 5 ] ]
  }.freeze

  TRANSFER_FIELDS = {
    from_account_id: :uuid, to_account_id: :uuid, idempotency_key: :uuid,
    amount: :number, source_fee_amount: :number, destination_fee_amount: :number, exchange_rate: :number,
    date: :date, tag_ids: :tag_ids
  }.freeze

  test "create refuses wrong shaped values in every field" do
    ApiRateLimiter.stubs(:limit).returns(nil)

    TRANSFER_FIELDS.each do |field, kind|
      WRONG_SHAPES.fetch(kind).each do |bad|
        assert_transfer_rejected(as: :json, field => bad)
        assert_includes JSON.parse(response.body)["message"], field.to_s, "#{field}=#{bad.inspect}"
      end
    end
  end

  test "create treats an idempotency key in another letter case as the same key" do
    key = SecureRandom.uuid
    post_transfer(idempotency_key: key)
    assert_response :created

    assert_no_difference "Transfer.count" do
      post_transfer(idempotency_key: key.upcase)
    end

    assert_response :ok
  end

  test "create refuses an exchange_rate between accounts of the same currency" do
    assert_transfer_rejected(exchange_rate: "7")
  end

  test "create accepts JSON numbers and zero" do
    post_transfer(as: :json, to_account_id: euro_account.id, amount: 10, exchange_rate: 0.5, source_fee_amount: 0.25, destination_fee_amount: 0)

    assert_response :created
    transfer = Transfer.find(JSON.parse(response.body)["id"])
    assert_equal 10, transfer.outflow_transaction.entry.amount
    assert_equal(-5, transfer.inflow_transaction.entry.amount)
    assert_equal 0.25, transfer.derived_source_fee_amount
  end

  test "create replays a keyed request that left the date out even on a later day" do
    key = SecureRandom.uuid
    post_transfer(as: :json, idempotency_key: key, date: nil)
    assert_response :created
    first_id = JSON.parse(response.body)["id"]

    travel_to 1.day.from_now do
      assert_no_difference "Transfer.count" do
        post_transfer(as: :json, idempotency_key: key, date: nil)
      end

      assert_response :ok
      assert_equal first_id, JSON.parse(response.body)["id"]
    end
  end

  test "create rejects amounts, fees and rates that are missing, not finite or outside the stored range" do
    {
      amount: [ nil, "0", "-5", "abc", "1000000000000000", "1e400", "Infinity", "NaN", "1,250.50", "12abc", "0.00001", "0.12345" ],
      source_fee_amount: [ "abc", "-1", "1000000000000000", "0.00001" ],
      destination_fee_amount: [ "abc", "Infinity" ],
      exchange_rate: [ "abc", "0", "-2", "Infinity" ]
    }.each do |field, values|
      values.each { |value| assert_transfer_rejected(field => value) }
    end
  end

  test "create rejects a converted amount that overflows the stored range" do
    assert_transfer_rejected(to_account_id: euro_account.id, amount: "999999999999999", exchange_rate: "1000")
  end

  test "create rejects tag_ids that are not the family's" do
    foreign_tag = families(:empty).tags.create!(name: "Not yours")

    [ [ SecureRandom.uuid ], [ foreign_tag.id ] ].each do |tag_ids|
      assert_transfer_rejected(tag_ids: tag_ids, as: :json)
    end
  end

  test "create answers a missing transfer with 400 and a wrong-typed transfer with 422" do
    post api_v1_transfers_url, params: {}, headers: api_headers(write_api_key), as: :json
    assert_response :bad_request

    [ "", {}, nil ].each do |transfer|
      post api_v1_transfers_url, params: { transfer: transfer }, headers: api_headers(write_api_key), as: :json
      assert_response :bad_request, "transfer #{transfer.inspect}"
    end

    [ "foo", [ 1 ], [] ].each do |transfer|
      assert_no_difference "Transfer.count" do
        post api_v1_transfers_url, params: { transfer: transfer }, headers: api_headers(write_api_key), as: :json
      end
      assert_response :unprocessable_entity, "transfer #{transfer.inspect}"
    end
  end

  test "create requires both accounts" do
    assert_no_difference "Transfer.count" do
      post api_v1_transfers_url, params: { transfer: create_params.except(:to_account_id) }, headers: api_headers(write_api_key)
    end

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "create rejects the same account on both sides" do
    assert_transfer_rejected(to_account_id: @account.id)
  end

  test "create cannot use an account the caller can only read" do
    @account.update_columns(owner_id: users(:family_member).id)
    AccountShare.create!(account: @account, user: @user, permission: "read_only")

    assert_transfer_rejected(status: :not_found)
  end

  test "create cannot use a disabled account" do
    @destination_account.update!(status: "disabled")

    assert_transfer_rejected(status: :not_found)
  end

  test "create cannot touch another family's account" do
    other_account = families(:empty).accounts.create!(name: "Foreign", accountable: Depository.new, balance: 0, currency: "USD")

    assert_transfer_rejected(to_account_id: other_account.id, status: :not_found)
  end

  private

    def create_transaction(account, amount:, date:, name:)
      entry = account.entries.create!(
        date: date,
        amount: amount,
        name: name,
        currency: account.currency,
        entryable: Transaction.new(kind: "funds_movement")
      )
      entry.entryable
    end

    def create_params(overrides = {})
      {
        from_account_id: @account.id,
        to_account_id: @destination_account.id,
        amount: "10",
        date: "2024-01-20"
      }.merge(overrides)
    end

    def post_transfer(as: nil, **overrides)
      post api_v1_transfers_url, params: { transfer: create_params(overrides) }, headers: api_headers(write_api_key), as: as
    end

    def assert_transfer_rejected(status: :unprocessable_entity, as: nil, **overrides)
      assert_no_difference "Transfer.count" do
        post_transfer(as: as, **overrides)
      end

      assert_response status, "#{overrides.inspect} should answer #{status}"
    end

    def euro_account
      @euro_account ||= @family.accounts.create!(name: "Transfer Euro", accountable: Depository.new, balance: 0, currency: "EUR")
    end

    def write_api_key
      @write_api_key ||= ApiKey.create!(
        user: @user,
        name: "Test Write Key",
        scopes: [ "read_write" ],
        source: "mobile",
        display_key: "test_write_#{SecureRandom.hex(8)}"
      )
    end

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end

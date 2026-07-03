# frozen_string_literal: true

require "test_helper"

class Api::V1::ImportSessionsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @api_key = api_keys(:active_key)
    @read_only_api_key = api_keys(:one)

    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_only_api_key.id}")
  end

  test "creates an idempotent Sure import session" do
    assert_difference("ImportSession.count", 1) do
      post api_v1_import_sessions_url,
           params: {
             type: "SureImport",
             client_session_id: "client-session-1",
             expected_chunks: 2
           },
           headers: api_headers(@api_key)
    end

    assert_response :created
    first_id = JSON.parse(response.body).dig("data", "id")

    assert_no_difference("ImportSession.count") do
      post api_v1_import_sessions_url,
           params: {
             type: "SureImport",
             client_session_id: "client-session-1",
             expected_chunks: 2
           },
           headers: api_headers(@api_key)
    end

    assert_response :created
    assert_equal first_id, JSON.parse(response.body).dig("data", "id")
  end

  test "rejects unsupported import session types" do
    assert_no_difference("ImportSession.count") do
      post api_v1_import_sessions_url,
           params: { type: "TransactionImport" },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "rejects malformed expected chunk counts" do
    assert_no_difference("ImportSession.count") do
      post api_v1_import_sessions_url,
           params: { type: "SureImport", expected_chunks: "2abc" },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "requires authentication for session creation" do
    post api_v1_import_sessions_url, params: { type: "SureImport" }

    assert_response :unauthorized
    assert_equal "unauthorized", JSON.parse(response.body)["error"]
  end

  test "uploads ordered chunks and publishes a full-fidelity transaction import" do
    session = build_import_session

    post chunks_api_v1_import_session_url(session),
         params: {
           sequence: 1,
           client_chunk_id: "entities",
           raw_file_content: build_ndjson(entity_records)
         },
         headers: api_headers(@api_key)

    assert_response :created
    assert_equal 1, JSON.parse(response.body).dig("data", "chunks_count")

    post chunks_api_v1_import_session_url(session),
         params: {
           sequence: 2,
           client_chunk_id: "transactions",
           raw_file_content: build_ndjson(transaction_records)
         },
         headers: api_headers(@api_key)

    assert_response :created

    perform_enqueued_jobs do
      post publish_api_v1_import_session_url(session), headers: api_headers(@api_key)
    end

    assert_response :accepted
    session.reload
    assert session.complete?
    assert_equal 1, session.summary.dig("transactions", "created")

    entry = @family.accounts.find_by!(name: "API Session Checking").entries.find_by!(name: "API Grocery Run")
    transaction = entry.entryable
    assert_equal "API Groceries", transaction.category.name
    assert_equal "API Market", transaction.merchant.name
    assert_equal [ "API Weekly" ], transaction.tags.map(&:name)
  end

  test "rejects replayed chunk with different content" do
    session = build_import_session
    params = {
      sequence: 1,
      client_chunk_id: "entities",
      raw_file_content: build_ndjson(entity_records)
    }

    post chunks_api_v1_import_session_url(session), params: params, headers: api_headers(@api_key)
    assert_response :created

    post chunks_api_v1_import_session_url(session),
         params: params.merge(raw_file_content: build_ndjson(transaction_records)),
         headers: api_headers(@api_key)

    assert_response :conflict
    assert_equal "import_session_conflict", JSON.parse(response.body)["error"]
  end

  test "requires chunk sequence" do
    session = build_import_session

    post chunks_api_v1_import_session_url(session),
         params: { raw_file_content: build_ndjson(entity_records) },
         headers: api_headers(@api_key)

    assert_response :bad_request
    assert_equal "bad_request", JSON.parse(response.body)["error"]
  end

  test "rejects malformed chunk sequence values" do
    session = build_import_session

    post chunks_api_v1_import_session_url(session),
         params: { sequence: "1abc", raw_file_content: build_ndjson(entity_records) },
         headers: api_headers(@api_key)

    assert_response :conflict
    assert_equal "import_session_conflict", JSON.parse(response.body)["error"]
  end

  test "shows import session with read scope" do
    session = build_import_session

    get api_v1_import_session_url(session), headers: api_headers(@read_only_api_key)

    assert_response :success
    data = JSON.parse(response.body)["data"]
    assert_equal session.id, data["id"]
    assert_equal "SureImport", data["type"]
  end

  test "shows chunks in sequence order" do
    session = build_import_session
    session.imports.create!(
      family: @family,
      type: "SureImport",
      sequence: 2,
      checksum: Digest::SHA256.hexdigest("two")
    )
    session.imports.create!(
      family: @family,
      type: "SureImport",
      sequence: 1,
      checksum: Digest::SHA256.hexdigest("one")
    )

    get api_v1_import_session_url(session), headers: api_headers(@api_key)

    assert_response :success
    assert_equal [ 1, 2 ], JSON.parse(response.body).dig("data", "chunks").map { |chunk| chunk["sequence"] }
  end

  test "requires write scope for session mutation" do
    assert_no_difference("ImportSession.count") do
      post api_v1_import_sessions_url,
           params: { type: "SureImport" },
           headers: api_headers(@read_only_api_key)
    end

    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]
  end

  test "rejects publishing a session with no chunks" do
    session = @family.import_sessions.create!

    post publish_api_v1_import_session_url(session), headers: api_headers(@api_key)

    assert_response :conflict
    assert_equal "import_session_conflict", JSON.parse(response.body)["error"]
  end

  test "returns stable error when publish cannot enqueue" do
    session = build_import_session
    session.attach_chunk!(
      sequence: 1,
      content: build_ndjson(entity_records),
      filename: "entities.ndjson",
      content_type: "application/x-ndjson"
    )
    session.attach_chunk!(
      sequence: 2,
      content: build_ndjson(transaction_records),
      filename: "transactions.ndjson",
      content_type: "application/x-ndjson"
    )

    ImportSessionJob.stub(:perform_later, ->(_import_session) { raise StandardError, "redis://secret.local/0" }) do
      post publish_api_v1_import_session_url(session), headers: api_headers(@api_key)
    end

    assert_response :service_unavailable
    body = JSON.parse(response.body)
    assert_equal "import_enqueue_failed", body["error"]
    assert_equal "Import session could not be queued.", body["message"]
    assert_no_match(/secret/, response.body)
  end

  test "does not expose another family's import session" do
    other_family = Family.create!(name: "Other Family", currency: "USD", locale: "en")
    other_session = other_family.import_sessions.create!

    get api_v1_import_session_url(other_session), headers: api_headers(@api_key)

    assert_response :not_found
  end

  private
    def build_import_session
      @family.import_sessions.create!(expected_chunks: 2)
    end

    def entity_records
      [
        {
          type: "Account",
          data: {
            id: "api-acct-1",
            name: "API Session Checking",
            balance: "100.00",
            currency: "USD",
            accountable_type: "Depository"
          }
        },
        {
          type: "Category",
          data: {
            id: "api-cat-1",
            name: "API Groceries",
            color: "#407706",
            classification: "expense"
          }
        },
        {
          type: "Merchant",
          data: {
            id: "api-merchant-1",
            name: "API Market"
          }
        },
        {
          type: "Tag",
          data: {
            id: "api-tag-1",
            name: "API Weekly"
          }
        }
      ]
    end

    def transaction_records
      [
        {
          type: "Transaction",
          data: {
            id: "api-txn-1",
            account_id: "api-acct-1",
            category_id: "api-cat-1",
            merchant_id: "api-merchant-1",
            tag_ids: [ "api-tag-1" ],
            date: "2024-01-15",
            amount: "-12.34",
            currency: "USD",
            name: "API Grocery Run"
          }
        }
      ]
    end

    def build_ndjson(records)
      records.map(&:to_json).join("\n")
    end
end

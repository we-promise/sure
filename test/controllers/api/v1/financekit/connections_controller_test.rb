require "test_helper"
require "rswag/specs/extended_schema"
require_relative "../../../../support/financekit_test_helper"

class Api::V1::Financekit::ConnectionsControllerTest < ActionDispatch::IntegrationTest
  include FinancekitTestHelper
  include ActiveJob::TestHelper

  setup do
    financekit_setup
    @user.api_keys.active.destroy_all
    @key = ApiKey.create!(user: @user, name: "FinanceKit test", scopes: [ "read_write" ],
      display_key: "test_#{SecureRandom.hex(16)}", source: "web")
    @headers = { "X-Api-Key" => @key.display_key }
    @publisher_headers = { "Authorization" => "Bearer #{@credential}", "Content-Type" => "application/json" }
    ApiRateLimiter.stubs(:limit).returns(nil)
    clear_enqueued_jobs
  end

  test "capabilities are authenticated scoped and explicit about background delivery" do
    get "/api/v1/financekit/capabilities"
    assert_response :unauthorized

    get "/api/v1/financekit/capabilities", headers: @headers
    assert_response :success
    assert_equal true, response.parsed_body.fetch("available")
    assert_equal "background_publisher", response.parsed_body.fetch("delivery")
    assert_equal Financekit::VERSION, response.parsed_body.fetch("protocol_versions").sole

    @key.update!(scopes: [ "read" ])
    post "/api/v1/financekit/connections", params: @enrollment, headers: @headers, as: :json
    assert_response :forbidden
  end

  test "enrollment is idempotent and activation returns a one-purpose publisher configuration" do
    post "/api/v1/financekit/connections", params: @enrollment, headers: @headers, as: :json
    assert_response :success
    assert_equal @item.id, response.parsed_body.fetch("connection_id")

    post "/api/v1/financekit/connections/#{@item.id}/credential", headers: @headers
    assert_response :success
    body = response.parsed_body
    assert_equal Financekit::VERSION, body.fetch("protocol_version")
    assert_equal @item.publisher_id, body.fetch("publisher_id")
    assert_equal @source.financekit_account_lineage_id, body.fetch("account_bindings").sole.fetch("lineage_id")
    assert_match %r{/api/v1/financekit/publishers/#{@item.publisher_id}/batches\z}, body.fetch("upload_url")
    assert body.fetch("publisher_credential").present?
    assert_not_includes body.fetch("consent").keys, "recorded_at"
  end

  test "financial publisher parameters and consent are redacted from diagnostics" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("events" => financekit_events, "consent" => @enrollment.fetch("consent"),
      "publisher_credential" => @credential)

    assert_equal "[FILTERED]", filtered.fetch("events")
    assert_equal "[FILTERED]", filtered.fetch("consent")
    assert_equal "[FILTERED]", filtered.fetch("publisher_credential")
  end

  test "publisher credential uploads a durable batch but cannot call the general API" do
    payload = financekit_payload
    raw = JSON.generate(payload)
    headers = @publisher_headers.merge("X-Sure-Payload-SHA256" => Digest::SHA256.hexdigest(raw),
      "Idempotency-Key" => payload.fetch("batch_id"))

    assert_enqueued_with(job: FinancekitInboxJob) do
      post "/api/v1/financekit/publishers/#{@item.publisher_id}/batches", params: raw, headers: headers
    end
    assert_response :accepted
    assert_equal "accepted", response.parsed_body.fetch("status")
    assert_receipt_schema
    assert_equal raw, FinancekitBatch.sole.payload
    assert_empty @source.account.entries

    FinancekitInboxJob.perform_now(@item.id)
    get "/api/v1/financekit/publishers/#{@item.publisher_id}/batches/#{payload.fetch("batch_id")}",
      headers: @publisher_headers.except("Content-Type")
    assert_response :success
    assert_equal "applied", response.parsed_body.fetch("status")
    assert_receipt_schema
    assert response.parsed_body.fetch("applied_at").present?

    get "/api/v1/accounts", headers: { "Authorization" => "Bearer #{@credential}" }
    assert_response :unauthorized
  end

  test "lost upload response can be retried for the same receipt" do
    payload = financekit_payload
    raw = JSON.generate(payload)
    headers = @publisher_headers.merge("X-Sure-Payload-SHA256" => Digest::SHA256.hexdigest(raw),
      "Idempotency-Key" => payload.fetch("batch_id"))

    post "/api/v1/financekit/publishers/#{@item.publisher_id}/batches", params: raw, headers: headers
    first_receipt = response.parsed_body
    assert_response :accepted

    assert_no_difference "FinancekitBatch.count" do
      post "/api/v1/financekit/publishers/#{@item.publisher_id}/batches", params: raw, headers: headers
    end
    assert_response :accepted
    assert_equal first_receipt, response.parsed_body
  end

  test "publisher endpoint rejects invalid revoked and oversized credentials or bodies" do
    post "/api/v1/financekit/publishers/#{@item.publisher_id}/batches", params: JSON.generate(financekit_payload),
      headers: @publisher_headers.merge("Authorization" => "Bearer invalid")
    assert_response :unauthorized

    @item.disconnect!
    post "/api/v1/financekit/publishers/#{@item.publisher_id}/batches", params: JSON.generate(financekit_payload),
      headers: @publisher_headers
    assert_response :unauthorized

    post "/api/v1/financekit/publishers/#{@item.publisher_id}/batches", params: "x" * (Financekit::MAX_BYTES + 1),
      headers: @publisher_headers.merge("Content-Length" => (Financekit::MAX_BYTES + 1).to_s)
    assert_response :payload_too_large
  end

  test "connection health separates device receipt import and downstream timestamps" do
    batch = accept_and_apply
    @item.reload

    get "/api/v1/financekit/connections/#{@item.id}", headers: @headers
    assert_response :success
    body = response.parsed_body
    assert_not_nil body.fetch("last_device_contact_at")
    assert_not_nil body.fetch("last_accepted_at")
    assert_not_nil body.fetch("last_imported_at")
    assert_not_nil body.fetch("last_downstream_at")
    assert_equal batch.applied_at.iso8601(3), Time.iso8601(body.fetch("last_imported_at")).iso8601(3)
  end

  test "conflicts are visible and require an explicit resolution" do
    first = accept_and_apply
    @source.account.entries.sole.update!(import_locked: true)
    tombstone = {
      "kind" => "transaction_tombstone",
      "tombstone" => {
        "source_id" => @transaction_id,
        "source_account_id" => @source_id,
        "lineage_id" => @source.financekit_account_lineage_id,
        "mapping_version" => @source.mapping_version
      }
    }
    accept_and_apply(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest, events: [ tombstone ]))
    conflict = @item.financekit_conflicts.sole

    get "/api/v1/financekit/connections/#{@item.id}/conflicts", headers: @headers
    assert_response :success
    assert_equal conflict.id, response.parsed_body.fetch("conflicts").sole.fetch("id")

    patch "/api/v1/financekit/connections/#{@item.id}/conflicts/#{conflict.id}",
      params: { resolution: "keep_sure" }, headers: @headers, as: :json
    assert_response :success
    assert_equal "resolved", conflict.reload.status
    assert_not conflict.financekit_transaction.reload.review_required?

    get "/api/v1/financekit/connections/#{@item.id}/conflicts", headers: @headers
    assert_response :success
    assert_empty response.parsed_body.fetch("conflicts")
  end

  test "retry after repair resolution fences the publisher stream" do
    first = accept_and_apply
    @source.account.entries.sole.update!(import_locked: true)
    tombstone = {
      "kind" => "transaction_tombstone",
      "tombstone" => {
        "source_id" => @transaction_id,
        "source_account_id" => @source_id,
        "lineage_id" => @source.financekit_account_lineage_id,
        "mapping_version" => @source.mapping_version
      }
    }
    second = accept_and_apply(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest, events: [ tombstone ]))
    queued, = accept_batch(financekit_payload(sequence: 3, predecessor_digest: second.payload_digest, events: []))
    conflict = @item.financekit_conflicts.sole
    old_credential = @credential

    patch "/api/v1/financekit/connections/#{@item.id}/conflicts/#{conflict.id}",
      params: { resolution: "retry_after_repair" }, headers: @headers, as: :json
    assert_response :success

    assert_equal "resolved", conflict.reload.status
    assert_equal "retry_after_repair", conflict.resolution
    assert_equal "repair_required", @item.reload.status
    assert_equal "conflict_retry_requested", @item.repair_reason
    assert_nil @item.credential_digest
    assert_equal "revoked", queued.reload.status
    assert_equal "conflict_retry_requested", queued.error_code

    payload = financekit_payload(sequence: 3, predecessor_digest: second.payload_digest, events: [])
    post "/api/v1/financekit/publishers/#{@item.publisher_id}/batches", params: JSON.generate(payload),
      headers: @publisher_headers.merge("Authorization" => "Bearer #{old_credential}")
    assert_response :unauthorized
  end

  test "non-admin and foreign-family access is rejected" do
    # Admin is the only thing standing between a family member and the publisher
    # endpoints now, so this is the whole access check rather than one of three.
    member = users(:family_member)
    key = ApiKey.create!(user: member, name: "FinanceKit member test", scopes: [ "read_write" ],
      display_key: "test_#{SecureRandom.hex(16)}", source: "web")

    get "/api/v1/financekit/capabilities", headers: { "X-Api-Key" => key.display_key }
    assert_response :forbidden
    assert_equal "publisher_forbidden", response.parsed_body.fetch("error")

    # Another family's admin clears the access check, since admin is all it asks,
    # and is stopped by tenancy instead: the connection scope is the caller's own
    # family and own user, so the row is simply not there. That is 404 rather
    # than the 403 the preview gate used to produce, which is the better answer —
    # it does not confirm to an outsider that the id exists.
    other = users(:empty)
    assert other.admin?
    assert_not_equal @family.id, other.family_id
    other_key = ApiKey.create!(user: other, name: "FinanceKit other test", scopes: [ "read" ],
      display_key: "test_#{SecureRandom.hex(16)}", source: "web")
    get "/api/v1/financekit/connections/#{@item.id}", headers: { "X-Api-Key" => other_key.display_key }
    assert_response :not_found
  end

  test "disconnecting retains imported history unless the client asks otherwise" do
    accept_and_apply
    account = @source.account

    delete "/api/v1/financekit/connections/#{@item.id}", headers: @headers
    assert_response :no_content

    # The response a client already gets, and the behaviour the published spec
    # promises: the connection goes, the money stays.
    assert_equal "revoked", @item.reload.status
    assert_nil @item.purge_requested_at
    assert_equal 1, account.entries.where(source: "financekit").count
    assert_empty enqueued_jobs.select { |job| job[:job] == FinancekitPurgeJob }
  end

  test "disconnecting with discard is accepted and hands the deletion to a job" do
    accept_and_apply

    # Query string, which is what the published spec documents: a DELETE body is
    # not carried reliably by every HTTP client.
    delete "/api/v1/financekit/connections/#{@item.id}?disposition=discard", headers: @headers

    # Accepted rather than completed: a year of history is not deleted inside a
    # request, so the client polls the connection for purge_completed_at.
    assert_response :accepted
    assert_equal "discard", response.parsed_body.fetch("disposition")
    assert_equal "revoked", response.parsed_body.fetch("status")
    assert_not_nil response.parsed_body.fetch("purge_requested_at")
    assert_nil response.parsed_body.fetch("purge_completed_at")
    assert_equal 1, enqueued_jobs.count { |job| job[:job] == FinancekitPurgeJob }
  end

  test "an unknown disposition is refused without revoking the connection" do
    delete "/api/v1/financekit/connections/#{@item.id}?disposition=shred", headers: @headers

    assert_response :unprocessable_entity
    assert_equal "invalid_disposition", response.parsed_body.fetch("error")
    assert_equal "active", @item.reload.status
  end

  test "an admin needs no server configuration or preview opt-in to publish" do
    # There is no FINANCEKIT_ENABLED flag, no family allowlist and no preview
    # toggle any more: whether a build offers Wallet sync is decided in the iOS
    # client through StoreKit, which the server cannot see. The test helper grants
    # neither, so the rest of this suite exercises the same thing implicitly.
    assert_not @user.preview_features_enabled?
    assert @user.admin?

    get "/api/v1/financekit/capabilities", headers: @headers
    assert_response :success
    assert_equal true, response.parsed_body.fetch("available")

    post "/api/v1/financekit/connections", params: @enrollment, headers: @headers, as: :json
    assert_response :success

    # And the publisher credential still works, so require_publisher! is not
    # gating on anything either.
    batch, = accept_batch
    assert_equal "accepted", batch.status
  end

  test "capabilities advertise the dispositions this build supports" do
    get "/api/v1/financekit/capabilities", headers: @headers

    assert_response :success
    # Feature-detected rather than hardcoded, so a client keeps working when a
    # provider gains discard or a build withholds it.
    assert_equal %w[retain discard], response.parsed_body.fetch("connection_dispositions")
  end

  private

    def assert_receipt_schema
      schemas = JSON.parse(Rails.root.join("docs/api/financekit/schemas.json").read)
      schema = schemas.fetch("FinancekitBatchReceipt").merge(
        "$schema" => "http://tempuri.org/rswag/specs/extended_schema")
      assert_empty JSON::Validator.fully_validate(schema, response.body)
    end
end

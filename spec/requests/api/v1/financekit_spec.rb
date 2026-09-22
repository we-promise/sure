require "swagger_helper"

RSpec.describe "Api::V1::Financekit", type: :request do
  FINANCEKIT_READ_SECURITY = [ { apiKeyAuth: [] }, { oauth2: %w[read] } ].freeze
  FINANCEKIT_WRITE_SECURITY = [ { apiKeyAuth: [] }, { oauth2: %w[read_write] } ].freeze
  FINANCEKIT_PUBLISHER_SECURITY = [ { financekitPublisher: [] } ].freeze

  let(:family) do
    Family.create!(name: "FinanceKit API Family", currency: "USD", locale: "en", date_format: "%m-%d-%Y")
  end
  let(:user) do
    family.users.create!(email: "financekit-api-#{SecureRandom.hex(8)}@example.com", password: "password123",
      password_confirmation: "password123", role: "admin", preferences: { "preview_features_enabled" => true })
  end
  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(user: user, name: "API Docs Key", key: key, scopes: %w[read_write], source: "web")
  end
  let(:'X-Api-Key') { api_key.plain_key }
  let(:source_id) { SecureRandom.uuid }
  let(:enrollment_input) do
    { protocol_version: 2, enrollment_id: SecureRandom.uuid,
      consent: { version: 1, granted_at: Time.current.iso8601, selected_source_account_ids: [ source_id ],
        upload_authorized: true, family_visibility_acknowledged: true, remote_processing_acknowledged: true } }
  end
  let(:connection) { Financekit::Enrollment.create!(user, enrollment_input.deep_stringify_keys).item }
  let(:mapping_input) do
    { expected_version: 0, action: "create", name: "Wallet Checking", institution_name: "Apple Wallet",
      currency: "USD", accountable_type: "Depository", subtype: "checking", ledger_timezone: "America/New_York",
      booked_balance: { amount: "25.00", currency: "USD", direction: "credit" }, observed_at: Time.current.iso8601 }
  end
  let(:mapping) { FinancekitAccount.map!(connection, source_id, mapping_input.deep_stringify_keys) }
  let(:publisher_credential) { mapping && connection.activate! }
  let(:id) { connection.id }
  let(:connection_id) { connection.id }
  let(:page) { nil }
  let(:per_page) { nil }

  before do
    allow(Financekit).to receive(:enabled?).and_return(true)
    allow(ApiRateLimiter).to receive(:limit).and_return(nil)
  end

  shared_examples "financekit normal API errors" do
    response "400", "Malformed or unsupported protocol" do
      schema "$ref" => "#/components/schemas/FinancekitError"
    end
    response "401", "Invalid or missing authentication" do
      schema "$ref" => "#/components/schemas/FinancekitError"
    end
    response "403", "Insufficient permission or publisher eligibility" do
      schema "$ref" => "#/components/schemas/FinancekitError"
    end
    response "409", "Enrollment, mapping, lineage, generation, or stream conflict" do
      schema "$ref" => "#/components/schemas/FinancekitError"
    end
    response "422", "Invalid typed record or consent" do
      schema "$ref" => "#/components/schemas/FinancekitError"
    end
    response "503", "Feature unavailable" do
      schema "$ref" => "#/components/schemas/FinancekitError"
      header "Retry-After", schema: { type: :integer }
    end
  end

  path "/api/v1/financekit/capabilities" do
    get "Discover FinanceKit background publisher support" do
      tags "FinanceKit"
      produces "application/json"
      security FINANCEKIT_READ_SECURITY
      response "200", "Publisher limits and protocol versions" do
        schema "$ref" => "#/components/schemas/FinancekitCapabilities"
        run_test!
      end
      include_examples "financekit normal API errors"
    end
  end

  path "/api/v1/financekit/connections" do
    post "Enroll a FinanceKit device publisher" do
      tags "FinanceKit"
      consumes "application/json"
      produces "application/json"
      security FINANCEKIT_WRITE_SECURITY
      parameter name: :body, in: :body, required: true, schema: { "$ref" => "#/components/schemas/FinancekitEnrollment" }
      response "201", "Publisher enrolled pending account mapping" do
        let(:body) { enrollment_input }
        schema "$ref" => "#/components/schemas/FinancekitConnection"
        run_test!
      end
      include_examples "financekit normal API errors"
    end
  end

  path "/api/v1/financekit/connections/{id}" do
    parameter name: :id, in: :path, type: :string, format: :uuid, required: true
    get "Read publisher health and paginated mappings" do
      tags "FinanceKit"
      produces "application/json"
      security FINANCEKIT_READ_SECURITY
      parameter name: :page, in: :query, type: :integer
      parameter name: :per_page, in: :query, type: :integer
      response "200", "Publisher health" do
        schema "$ref" => "#/components/schemas/FinancekitConnection"
        run_test!
      end
      include_examples "financekit normal API errors"
    end
    delete "Revoke a publisher and retain imported financial history" do
      tags "FinanceKit"
      security FINANCEKIT_WRITE_SECURITY
      response "204", "Publisher revoked" do
        run_test!
      end
      include_examples "financekit normal API errors"
    end
  end

  path "/api/v1/financekit/connections/{connection_id}/account_mappings/{source_id}" do
    parameter name: :connection_id, in: :path, type: :string, format: :uuid, required: true
    parameter name: :source_id, in: :path, type: :string, format: :uuid, required: true
    put "Explicitly create or link a canonical account lineage" do
      tags "FinanceKit"
      consumes "application/json"
      produces "application/json"
      security FINANCEKIT_WRITE_SECURITY
      parameter name: :body, in: :body, required: true, schema: { "$ref" => "#/components/schemas/FinancekitMappingRequest" }
      response "200", "Stable account lineage binding" do
        let(:body) { mapping_input }
        schema "$ref" => "#/components/schemas/FinancekitAccountMapping"
        run_test!
      end
      include_examples "financekit normal API errors"
    end
  end

  %w[activate credential repair].each do |operation|
    path "/api/v1/financekit/connections/{connection_id}/#{operation}" do
      parameter name: :connection_id, in: :path, type: :string, format: :uuid, required: true
      post "#{operation.capitalize} the background publisher" do
        tags "FinanceKit"
        produces "application/json"
        security FINANCEKIT_WRITE_SECURITY
        response "200", "Publisher configuration and a newly issued restricted credential" do
          before do
            mapping
            connection.activate! if operation != "activate"
          end
          schema "$ref" => "#/components/schemas/FinancekitPublisherConfiguration"
          run_test!
        end
        include_examples "financekit normal API errors"
      end
    end
  end

  path "/api/v1/financekit/publishers/{publisher_id}/batches" do
    parameter name: :publisher_id, in: :path, type: :string, format: :uuid, required: true
    post "Durably accept an ordered FinanceKit publisher batch" do
      tags "FinanceKit"
      consumes "application/json"
      produces "application/json"
      security FINANCEKIT_PUBLISHER_SECURITY
      parameter name: :Authorization, in: :header, type: :string, required: true
      parameter name: :'Idempotency-Key', in: :header, type: :string, format: :uuid, required: false
      parameter name: :'X-Sure-Payload-SHA256', in: :header, type: :string, required: false
      parameter name: :body, in: :body, required: true, schema: { "$ref" => "#/components/schemas/FinancekitBatch" }
      let(:publisher_id) { connection.publisher_id }
      let(:Authorization) { "Bearer #{publisher_credential}" }
      let(:body) do
        { protocol_version: 2, connection_id: connection.id, publisher_id: connection.publisher_id,
          generation: connection.generation, stream_id: connection.stream_id, batch_id: SecureRandom.uuid,
          sequence: 1, capture_id: SecureRandom.uuid, chunk_index: 0, chunk_count: 1, capture_mode: "delta",
          snapshot_complete: false, captured_at: Time.current.iso8601, selected_source_account_ids: [ source_id ],
          events: [] }
      end
      response "202", "Immutable bytes accepted into the inbox" do
        schema "$ref" => "#/components/schemas/FinancekitBatchReceipt"
        run_test!
      end
      response "401", "Invalid publisher credential" do
        schema "$ref" => "#/components/schemas/FinancekitError"
      end
      response "409", "Digest, sequence, predecessor, generation, or idempotency conflict" do
        schema "$ref" => "#/components/schemas/FinancekitError"
      end
      response "413", "Payload or record limit exceeded" do
        schema "$ref" => "#/components/schemas/FinancekitError"
      end
      response "429", "Publisher inbox full" do
        schema "$ref" => "#/components/schemas/FinancekitError"
        header "Retry-After", schema: { type: :integer }
      end
    end
  end

  path "/api/v1/financekit/publishers/{publisher_id}/batches/{batch_id}" do
    parameter name: :publisher_id, in: :path, type: :string, format: :uuid, required: true
    parameter name: :batch_id, in: :path, type: :string, format: :uuid, required: true
    get "Read the durable receipt for an accepted batch" do
      tags "FinanceKit"
      produces "application/json"
      security FINANCEKIT_PUBLISHER_SECURITY
      parameter name: :Authorization, in: :header, type: :string, required: true
      let(:publisher_id) { connection.publisher_id }
      let(:Authorization) { "Bearer #{publisher_credential}" }
      let(:accepted_batch) do
        publisher_credential
        payload = { protocol_version: 2, connection_id: connection.id, publisher_id: connection.publisher_id,
          generation: connection.generation, stream_id: connection.stream_id, batch_id: SecureRandom.uuid,
          sequence: 1, capture_id: SecureRandom.uuid, chunk_index: 0, chunk_count: 1, capture_mode: "delta",
          snapshot_complete: false, captured_at: Time.current.iso8601,
          selected_source_account_ids: [ source_id ], events: [] }
        FinancekitBatch.accept!(connection, JSON.generate(payload.deep_stringify_keys))
      end
      let(:batch_id) { accepted_batch.batch_id }
      response "200", "Durable receipt for a previously accepted batch" do
        schema "$ref" => "#/components/schemas/FinancekitBatchReceipt"
        run_test!
      end
      response "401", "Invalid publisher credential" do
        schema "$ref" => "#/components/schemas/FinancekitError"
      end
      response "404", "No batch with that identity in the current generation" do
        schema "$ref" => "#/components/schemas/FinancekitError"
      end
    end
  end

  path "/api/v1/financekit/connections/{connection_id}/conflicts" do
    parameter name: :connection_id, in: :path, type: :string, format: :uuid, required: true
    get "List conflicts requiring user review" do
      tags "FinanceKit"
      produces "application/json"
      security FINANCEKIT_READ_SECURITY
      response "200", "Conflict collection" do
        schema type: :object, required: %w[conflicts], properties: {
          conflicts: { type: :array, items: { "$ref" => "#/components/schemas/FinancekitConflict" } }
        }
        run_test!
      end
      include_examples "financekit normal API errors"
    end
  end

  path "/api/v1/financekit/connections/{connection_id}/conflicts/{id}" do
    parameter name: :connection_id, in: :path, type: :string, format: :uuid, required: true
    parameter name: :id, in: :path, type: :string, format: :uuid, required: true
    patch "Resolve a FinanceKit import conflict" do
      tags "FinanceKit"
      consumes "application/json"
      produces "application/json"
      security FINANCEKIT_WRITE_SECURITY
      parameter name: :body, in: :body, required: true, schema: { "$ref" => "#/components/schemas/FinancekitConflictResolution" }
      let(:conflict) { connection.financekit_conflicts.create!(family: family, kind: "protected_tombstone", details: {}) }
      let(:id) { conflict.id }
      let(:body) { { resolution: "keep_sure" } }
      response "200", "Conflict resolved" do
        schema "$ref" => "#/components/schemas/FinancekitConflict"
        run_test!
      end
      include_examples "financekit normal API errors"
    end
  end
end

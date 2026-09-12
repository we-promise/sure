require "swagger_helper"

RSpec.describe "Api::V1::Financekit", type: :request do
  FINANCEKIT_SECURITY = [ { apiKeyAuth: [] }, { oauth2: %w[read_write] } ].freeze

  let(:family) do
    Family.create!(
      name: "FinanceKit API Family",
      currency: "USD",
      locale: "en",
      date_format: "%m-%d-%Y"
    )
  end

  let(:user) do
    family.users.create!(
      email: "financekit-api-#{SecureRandom.hex(8)}@example.com",
      password: "password123",
      password_confirmation: "password123",
      role: "admin",
      preferences: { "preview_features_enabled" => true }
    )
  end
  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(user: user, name: "API Docs Key", key: key, scopes: %w[read_write], source: "web")
  end
  let(:'X-Api-Key') { api_key.plain_key }
  let(:connection_source_id) { SecureRandom.uuid }
  let(:connection) do
    Financekit::Enrollment.create!(user, {
      "enrollment_id" => SecureRandom.uuid,
      "protocol" => 1,
      "consent" => { "version" => 1, "upload_authorized" => true, "enrichment_acknowledged" => true, "source_ids" => [ connection_source_id ] }
    })
  end
  let(:id) { connection.id }
  let(:page) { nil }
  let(:per_page) { nil }

  before do
    allow(Financekit).to receive(:enabled?).and_return(true)
    allow(ApiRateLimiter).to receive(:limit).and_return(nil)
  end

  shared_examples "financekit errors" do
    response "400", "Malformed or unsupported protocol" do
      schema "$ref" => "#/components/schemas/FinancekitError"
      it("documents response") { expect(true).to be(true) }
    end
    response "401", "Invalid or missing authentication" do
      schema "$ref" => "#/components/schemas/FinancekitError"
      it("documents response") { expect(true).to be(true) }
    end
    response "403", "Insufficient permissions or revoked publisher" do
      schema "$ref" => "#/components/schemas/FinancekitError"
      it("documents response") { expect(true).to be(true) }
    end
    response "404", "Resource not found" do
      schema "$ref" => "#/components/schemas/FinancekitError"
      it("documents response") { expect(true).to be(true) }
    end
    response "409", "Enrollment, mapping, stale capture or source identity conflict" do
      schema "$ref" => "#/components/schemas/FinancekitError"
      it("documents response") { expect(true).to be(true) }
    end
    response "413", "Payload or record limit exceeded" do
      schema "$ref" => "#/components/schemas/FinancekitError"
      it("documents response") { expect(true).to be(true) }
    end
    response "422", "Invalid records or consent" do
      schema "$ref" => "#/components/schemas/FinancekitError"
      it("documents response") { expect(true).to be(true) }
    end
    response "429", "Rate limited" do
      schema "$ref" => "#/components/schemas/FinancekitError"
      header "Retry-After", schema: { type: :integer }, description: "Minimum retry delay in seconds"
      it("documents response") { expect(true).to be(true) }
    end
    response "503", "Feature unavailable" do
      schema "$ref" => "#/components/schemas/FinancekitError"
      header "Retry-After", schema: { type: :integer }, description: "Minimum retry delay in seconds"
      it("documents response") { expect(true).to be(true) }
    end
  end

  path "/api/v1/financekit/capabilities" do
    get "Discover foreground FinanceKit sync support" do
      tags "FinanceKit"
      produces "application/json"
      security FINANCEKIT_SECURITY
      response "200", "Discover foreground FinanceKit sync support" do
        schema "$ref" => "#/components/schemas/FinancekitCapabilities"
        run_test!
      end
      include_examples "financekit errors"
    end
  end

  path "/api/v1/financekit/connections" do
    post "Enroll a FinanceKit foreground sync connection" do
      tags "FinanceKit"
      produces "application/json"
      security FINANCEKIT_SECURITY
      consumes "application/json"
      parameter name: :body, in: :body, required: true, schema: { "$ref" => "#/components/schemas/FinancekitEnrollment" }
      response "201", "Enroll a FinanceKit foreground sync connection" do
        let(:body) do
          { enrollment_id: SecureRandom.uuid, protocol: 1,
            consent: { version: 1, upload_authorized: true, enrichment_acknowledged: true, source_ids: [ SecureRandom.uuid ] } }
        end

        schema "$ref" => "#/components/schemas/FinancekitConnection"
        run_test!
      end
      include_examples "financekit errors"
    end
  end

  path "/api/v1/financekit/connections/{id}" do
    parameter name: :id, in: :path, type: :string, required: true

    get "Read connection health and paginated mappings" do
      tags "FinanceKit"
      produces "application/json"
      security FINANCEKIT_SECURITY
      parameter name: :page, in: :query, type: :integer
      parameter name: :per_page, in: :query, type: :integer
      response "200", "Read connection health and paginated mappings" do
        schema "$ref" => "#/components/schemas/FinancekitConnection"
        run_test!
      end
      include_examples "financekit errors"
    end

    delete "Revoke foreground sync access and retain existing financial history" do
      tags "FinanceKit"
      produces "application/json"
      security FINANCEKIT_SECURITY
      response "204", "Revoke foreground sync access and retain existing financial history" do
        run_test!
      end
      include_examples "financekit errors"
    end
  end

  path "/api/v1/financekit/connections/{connection_id}/account_mappings/{source_id}" do
    parameter name: :connection_id, in: :path, type: :string, required: true
    parameter name: :source_id, in: :path, type: :string, required: true

    put "Explicitly link or create a canonical account" do
      tags "FinanceKit"
      produces "application/json"
      security FINANCEKIT_SECURITY
      consumes "application/json"
      parameter name: :body, in: :body, required: true, schema: { "$ref" => "#/components/schemas/FinancekitMappingRequest" }
      response "200", "Explicitly link or create a canonical account" do
        let(:connection) do
          Financekit::Enrollment.create!(user, {
            "enrollment_id" => SecureRandom.uuid,
            "protocol" => 1,
            "consent" => { "version" => 1, "upload_authorized" => true, "enrichment_acknowledged" => true, "source_ids" => [ source_id ] }
          })
        end
        let(:connection_id) { connection.id }
        let(:source_id) { SecureRandom.uuid }
        let(:body) do
          { expected_version: 0, action: "create", name: "Wallet Checking", currency: "USD",
            accountable_type: "Depository", subtype: "checking", ledger_timezone: "America/New_York",
            booked_balance: { amount: "25.00", currency: "USD", credit_debit: "credit" },
            observed_at: Time.current.iso8601 }
        end

        schema "$ref" => "#/components/schemas/FinancekitAccountMapping"
        run_test!
      end
      include_examples "financekit errors"
    end
  end

  path "/api/v1/financekit/connections/{connection_id}/syncs" do
    parameter name: :connection_id, in: :path, type: :string, required: true

    post "Import a foreground FinanceKit sync payload" do
      tags "FinanceKit"
      produces "application/json"
      security FINANCEKIT_SECURITY
      consumes "application/json"
      parameter name: :body, in: :body, required: true, schema: { "$ref" => "#/components/schemas/FinancekitPayload" }
      response "201", "Import a foreground FinanceKit sync payload" do
        let(:connection) do
          Financekit::Enrollment.create!(user, {
            "enrollment_id" => SecureRandom.uuid,
            "protocol" => 1,
            "consent" => { "version" => 1, "upload_authorized" => true, "enrichment_acknowledged" => true, "source_ids" => [ source_id ] }
          })
        end
        let(:source_id) { SecureRandom.uuid }
        let(:source) do
          FinancekitAccount.map!(connection, source_id, {
            "expected_version" => 0, "action" => "create", "name" => "Wallet Checking", "currency" => "USD",
            "accountable_type" => "Depository", "subtype" => "checking", "ledger_timezone" => "America/New_York",
            "booked_balance" => { "amount" => "25.00", "currency" => "USD", "credit_debit" => "credit" },
            "observed_at" => Time.current.iso8601
          })
        end
        let(:connection_id) { connection.id }
        let(:body) do
          captured_at = Time.current.iso8601
          { captured_at: captured_at,
            history: { kind: "snapshot", snapshot_id: SecureRandom.uuid, start_at: 1.day.ago.iso8601, end_at: captured_at, complete: true },
            accounts: [ { source_id: source.source_id, mapping_version: source.mapping_version, observed_at: captured_at,
              booked_balance: { amount: "24.00", currency: "USD", credit_debit: "credit" } } ],
            transactions: [],
            tombstones: [] }
        end

        schema "$ref" => "#/components/schemas/FinancekitSyncResult"
        run_test!
      end
      include_examples "financekit errors"
    end
  end
end

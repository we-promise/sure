require "swagger_helper"

RSpec.describe "Api::V1::Financekit", type: :request do
  let(:user) { users(:family_admin) }
  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(user: user, name: "API Docs Key", key: key, scopes: %w[read_write], source: "web")
  end
  let(:'X-Api-Key') { api_key.plain_key }

  shared_examples "financekit errors" do
    response "400", "Malformed or unsupported protocol" do
      schema "$ref" => "#/components/schemas/FinancekitError"
      run_test!
    end
    response "401", "Invalid or missing authentication" do
      schema "$ref" => "#/components/schemas/FinancekitError"
      run_test!
    end
    response "403", "Insufficient permissions or revoked publisher" do
      schema "$ref" => "#/components/schemas/FinancekitError"
      run_test!
    end
    response "404", "Resource not found" do
      schema "$ref" => "#/components/schemas/FinancekitError"
      run_test!
    end
    response "409", "Enrollment, mapping, stale capture or source identity conflict" do
      schema "$ref" => "#/components/schemas/FinancekitError"
      run_test!
    end
    response "413", "Payload or record limit exceeded" do
      schema "$ref" => "#/components/schemas/FinancekitError"
      run_test!
    end
    response "422", "Invalid records or consent" do
      schema "$ref" => "#/components/schemas/FinancekitError"
      run_test!
    end
    response "429", "Rate limited" do
      schema "$ref" => "#/components/schemas/FinancekitError"
      header "Retry-After", schema: { type: :integer }, description: "Minimum retry delay in seconds"
      run_test!
    end
    response "503", "Feature unavailable" do
      schema "$ref" => "#/components/schemas/FinancekitError"
      header "Retry-After", schema: { type: :integer }, description: "Minimum retry delay in seconds"
      run_test!
    end
  end

  path "/api/v1/financekit/capabilities" do
    get "Discover foreground FinanceKit sync support" do
      tags "FinanceKit"
      produces "application/json"
      security [ { apiKeyAuth: [] } ]
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
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      parameter name: :body, in: :body, required: true, schema: { "$ref" => "#/components/schemas/FinancekitEnrollment" }
      response "201", "Enroll a FinanceKit foreground sync connection" do
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
      security [ { apiKeyAuth: [] } ]
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
      security [ { apiKeyAuth: [] } ]
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
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      parameter name: :body, in: :body, required: true, schema: { "$ref" => "#/components/schemas/FinancekitMappingRequest" }
      response "200", "Explicitly link or create a canonical account" do
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
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      parameter name: :body, in: :body, required: true, schema: { "$ref" => "#/components/schemas/FinancekitPayload" }
      response "201", "Import a foreground FinanceKit sync payload" do
        schema "$ref" => "#/components/schemas/FinancekitSyncResult"
        run_test!
      end
      include_examples "financekit errors"
    end
  end
end

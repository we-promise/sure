require "swagger_helper"

RSpec.describe "Api::V1::Financekit", type: :request do
  let(:user) { users(:family_admin) }
  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(user: user, name: "API Docs Key", key: key, scopes: %w[read_write], source: "web")
  end
  let(:'X-Api-Key') { api_key.plain_key }

  path "/api/v1/financekit/capabilities" do
    get "Discover device upload support" do
      tags "FinanceKit"
      produces "application/json"
      security [ { apiKeyAuth: [] } ]
      response "200", "Discover device upload support" do
        schema "$ref" => "#/components/schemas/FinancekitCapabilities"
        run_test!
      end
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
      response "409", "Identity generation mapping or sequence conflict" do
        schema "$ref" => "#/components/schemas/FinancekitError"
        run_test!
      end
      response "413", "Upload limit exceeded" do
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
  end

  path "/api/v1/financekit/connections" do
    post "Enroll a device with explicit upload consent" do
      tags "FinanceKit"
      produces "application/json"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      parameter name: :body, in: :body, required: true, schema: { "$ref" => "#/components/schemas/FinancekitEnrollment" }
      response "201", "Enroll a device with explicit upload consent" do
        schema "$ref" => "#/components/schemas/FinancekitConnection"
        run_test!
      end
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
      response "409", "Identity generation mapping or sequence conflict" do
        schema "$ref" => "#/components/schemas/FinancekitError"
        run_test!
      end
      response "413", "Upload limit exceeded" do
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
      response "409", "Identity generation mapping or sequence conflict" do
        schema "$ref" => "#/components/schemas/FinancekitError"
        run_test!
      end
      response "413", "Upload limit exceeded" do
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
  end

  path "/api/v1/financekit/connections/{id}" do
    parameter name: :id, in: :path, type: :string, required: true
    delete "Revoke uploads and retain existing financial history" do
      tags "FinanceKit"
      produces "application/json"
      security [ { apiKeyAuth: [] } ]
      response "204", "Revoke uploads and retain existing financial history" do
        run_test!
      end
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
      response "409", "Identity generation mapping or sequence conflict" do
        schema "$ref" => "#/components/schemas/FinancekitError"
        run_test!
      end
      response "413", "Upload limit exceeded" do
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
      response "409", "Identity generation mapping or sequence conflict" do
        schema "$ref" => "#/components/schemas/FinancekitError"
        run_test!
      end
      response "413", "Upload limit exceeded" do
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
  end

  path "/api/v1/financekit/connections/{connection_id}/device_replacement" do
    parameter name: :connection_id, in: :path, type: :string, required: true
    post "Fence previous generation and confirm publisher or selection" do
      tags "FinanceKit"
      produces "application/json"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      parameter name: :body, in: :body, required: true, schema: { "$ref" => "#/components/schemas/FinancekitReplacement" }
      response "200", "Fence previous generation and confirm publisher or selection" do
        schema "$ref" => "#/components/schemas/FinancekitConnection"
        run_test!
      end
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
      response "409", "Identity generation mapping or sequence conflict" do
        schema "$ref" => "#/components/schemas/FinancekitError"
        run_test!
      end
      response "413", "Upload limit exceeded" do
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
  end

  path "/api/v1/financekit/connections/{connection_id}/batches" do
    parameter name: :connection_id, in: :path, type: :string, required: true
    post "Durably accept an encrypted device-signed batch" do
      tags "FinanceKit"
      produces "application/json"
      security []
      consumes "application/jose"
      parameter name: :body, in: :body, required: true, schema: { type: :string, maxLength: 1048576, description: "ES256 compact JWS containing FinancekitEnvelopeClaims; never send general API credentials." }
      response "202", "Durably accept an encrypted device-signed batch" do
        schema "$ref" => "#/components/schemas/FinancekitReceipt"
        run_test!
      end
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
      response "409", "Identity generation mapping or sequence conflict" do
        schema "$ref" => "#/components/schemas/FinancekitError"
        run_test!
      end
      response "413", "Upload limit exceeded" do
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
  end

  path "/api/v1/financekit/connections/{connection_id}/batches/{batch_id}" do
    parameter name: :connection_id, in: :path, type: :string, required: true
    parameter name: :batch_id, in: :path, type: :string, required: true
    get "Read an authenticated batch receipt" do
      tags "FinanceKit"
      produces "application/json"
      security [ { apiKeyAuth: [] } ]
      parameter name: :generation, in: :query, type: :integer, required: true
      response "200", "Read an authenticated batch receipt" do
        schema "$ref" => "#/components/schemas/FinancekitReceipt"
        run_test!
      end
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
      response "409", "Identity generation mapping or sequence conflict" do
        schema "$ref" => "#/components/schemas/FinancekitError"
        run_test!
      end
      response "413", "Upload limit exceeded" do
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
  end
end

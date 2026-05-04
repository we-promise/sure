# frozen_string_literal: true

require "swagger_helper"

RSpec.describe "Api::V1::FamilyExports", type: :request do
  let(:user) { users(:family_admin) }
  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: "API Docs Key",
      key: key,
      scopes: %w[read_write],
      source: "web"
    )
  end
  let(:'X-Api-Key') { api_key.plain_key }
  let(:family_export) { user.family.family_exports.create!(status: "completed") }
  let(:id) { family_export.id }

  path "/api/v1/family_exports" do
    get "Lists family exports" do
      tags "Family Exports"
      security [ apiKeyAuth: [] ]
      produces "application/json"
      parameter name: :page, in: :query, type: :integer, required: false, description: "Page number (default: 1)"
      parameter name: :per_page, in: :query, type: :integer, required: false, description: "Items per page (default: 25, max: 100)"

      response "200", "family exports listed" do
        schema "$ref" => "#/components/schemas/FamilyExportCollection"
        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "forbidden" do
        let(:user) { users(:family_member) }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end

    post "Queues a family export" do
      tags "Family Exports"
      security [ apiKeyAuth: [] ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: false, schema: {
        type: :object,
        additionalProperties: false,
        description: "Family export creation does not accept request parameters."
      }

      let(:body) { {} }

      response "202", "family export queued" do
        schema "$ref" => "#/components/schemas/FamilyExportResponse"
        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "forbidden" do
        let(:user) { users(:family_member) }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "422", "invalid params" do
        let(:body) { { family_export: { status: "completed" } } }

        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/family_exports/{id}" do
    parameter name: :id, in: :path, type: :string, format: :uuid, required: true

    get "Shows a family export" do
      tags "Family Exports"
      security [ apiKeyAuth: [] ]
      produces "application/json"

      response "200", "family export shown" do
        schema "$ref" => "#/components/schemas/FamilyExportResponse"
        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "forbidden" do
        let(:user) { users(:family_member) }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "404", "not found" do
        let(:id) { SecureRandom.uuid }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/family_exports/{id}/download" do
    parameter name: :id, in: :path, type: :string, format: :uuid, required: true

    get "Downloads a completed family export" do
      tags "Family Exports"
      security [ apiKeyAuth: [] ]
      produces "application/json"

      response "302", "family export download redirected" do
        before do
          family_export.export_file.attach(
            io: StringIO.new("test zip content"),
            filename: "test.zip",
            content_type: "application/zip"
          )
        end

        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "forbidden" do
        let(:user) { users(:family_member) }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "404", "not found" do
        let(:id) { SecureRandom.uuid }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "409", "export not ready" do
        let(:family_export) { user.family.family_exports.create!(status: "processing") }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end
end

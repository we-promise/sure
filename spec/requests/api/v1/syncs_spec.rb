# frozen_string_literal: true

require "swagger_helper"

RSpec.describe "Api::V1::Syncs", type: :request do
  let(:family) do
    Family.create!(
      name: "API Family",
      currency: "USD",
      locale: "en",
      date_format: "%m-%d-%Y"
    )
  end

  let(:user) do
    family.users.create!(
      email: "sync-api-user@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: "API Docs Key",
      key: key,
      display_key: key,
      scopes: %w[read_write],
      source: "web"
    )
  end
  let(:api_key_without_read_scope) do
    key = ApiKey.generate_secure_key
    ApiKey.new(
      user: user,
      name: "No Read Docs Key",
      key: key,
      display_key: key,
      scopes: %w[write],
      source: "web"
    ).tap { |api_key| api_key.save!(validate: false) }
  end
  let(:'X-Api-Key') { api_key.plain_key }
  let(:sync) { Sync.create!(syncable: family, status: "completed", completed_at: 1.minute.ago) }
  let(:id) { sync.id }

  path "/api/v1/syncs" do
    get "Lists sync history" do
      description "List sanitized sync status history for the authenticated user's family, accounts, and provider connections."
      tags "Syncs"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"
      parameter name: :page, in: :query, type: :integer, required: false, description: "Page number (default: 1)"
      parameter name: :per_page, in: :query, type: :integer, required: false, description: "Items per page (default: 25, max: 100)"

      response "200", "syncs listed" do
        schema "$ref" => "#/components/schemas/SyncCollection"
        before { sync }
        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "forbidden" do
        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/syncs/latest" do
    get "Shows the latest sync" do
      description "Return the most recently created sanitized sync status for the authenticated user's family, or data: null when no sync exists."
      tags "Syncs"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"

      response "200", "latest sync shown" do
        schema "$ref" => "#/components/schemas/SyncResponse"
        before { sync }
        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "forbidden" do
        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/syncs/{id}" do
    parameter name: :id, in: :path, type: :string, format: :uuid, required: true

    get "Shows a sync" do
      description "Return sanitized status metadata for a single family-scoped sync."
      tags "Syncs"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"

      response "200", "sync shown" do
        schema "$ref" => "#/components/schemas/SyncResponse"
        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "forbidden" do
        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

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
end

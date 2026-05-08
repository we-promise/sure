# frozen_string_literal: true

require "swagger_helper"

RSpec.describe "Api::V1::ProviderConnections", type: :request do
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
  let(:api_key_without_read_scope) do
    key = ApiKey.generate_secure_key
    ApiKey.new(
      user: user,
      name: "API Docs Write Key",
      key: key,
      scopes: %w[write],
      source: "web"
    ).tap { |api_key| api_key.save!(validate: false) }
  end
  let(:'X-Api-Key') { api_key.plain_key }

  path "/api/v1/provider_connections" do
    get "Lists provider connection status summaries" do
      description "List safe provider connection status metadata for the authenticated user's family without exposing credentials, raw provider payloads, or raw sync errors."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"

      response "200", "provider connection status summaries listed" do
        schema "$ref" => "#/components/schemas/ProviderConnectionCollection"
        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "insufficient scope" do
        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end
end

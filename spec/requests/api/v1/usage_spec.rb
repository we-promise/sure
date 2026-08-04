# frozen_string_literal: true

require "swagger_helper"

# Documentation-only spec. Behavioural coverage for this endpoint belongs in
# test/controllers/api/v1/ (Minitest). Use run_test! without assertions here so
# the generated OpenAPI document stays a faithful description of the API.
RSpec.describe "Api::V1::Usage", type: :request do
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
      email: "usage-api-user@example.com",
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
      scopes: %w[read],
      source: "web"
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  path "/api/v1/usage" do
    get "Retrieves API key usage and rate limit status" do
      description "Returns the current rate limit window for the authenticated API key. OAuth-authenticated requests receive a short notice instead, because detailed usage is only tracked per API key."
      tags "Usage"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"

      response "200", "usage retrieved" do
        schema type: :object,
               properties: {
                 api_key: {
                   type: :object,
                   properties: {
                     name: { type: :string },
                     scopes: { type: :array, items: { type: :string } },
                     last_used_at: { type: :string, format: :"date-time", nullable: true },
                     created_at: { type: :string, format: :"date-time" }
                   }
                 },
                 rate_limit: {
                   type: :object,
                   properties: {
                     tier: { type: :string },
                     limit: { type: :integer },
                     current_count: { type: :integer },
                     remaining: { type: :integer },
                     reset_in_seconds: { type: :integer },
                     reset_at: { type: :string, format: :"date-time" }
                   }
                 }
               }

        run_test!
      end

      response "401", "unauthorized" do
        schema "$ref" => "#/components/schemas/ErrorResponse"
        let(:'X-Api-Key') { nil }

        run_test!
      end
    end
  end
end

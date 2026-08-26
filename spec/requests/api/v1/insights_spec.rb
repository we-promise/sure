# frozen_string_literal: true

require "swagger_helper"

RSpec.describe "API V1 Insights", type: :request do
  let(:family) { Family.create!(name: "API Family") }
  let(:user) do
    family.users.create!(
      email: "insights-api@example.com",
      password: "password123",
      ai_enabled: true,
      preferences: { "preview_features_enabled" => true }
    )
  end
  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(user: user, name: "API Docs Key", key: key, scopes: %w[read_write], source: "web")
  end
  let(:"X-Api-Key") { api_key.plain_key }

  path "/api/v1/insights" do
    get "List proactive insights" do
      tags "Insights"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"

      response "200", "insights listed" do
        schema "$ref" => "#/components/schemas/InsightCollection"
        run_test!
      end


      response "403", "preview features disabled" do
        schema "$ref" => "#/components/schemas/ErrorResponse"
        let(:user) do
          family.users.create!(
            email: "insights-disabled-api@example.com",
            password: "password123",
            ai_enabled: true,
            preferences: { "preview_features_enabled" => false }
          )
        end

        run_test!
      end
    end
  end
end

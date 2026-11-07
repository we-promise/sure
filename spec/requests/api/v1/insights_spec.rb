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
  path "/api/v1/insights/{id}/acknowledge" do
    patch "Acknowledge a proactive insight" do
      tags "Insights"
      description "Marks a visible family insight read and acknowledged, removing it from the feed. Requires read_write scope and preview access. Repeated requests are idempotent."
      security [ { apiKeyAuth: [] }, { oauth2: %w[read_write] } ]
      produces "application/json"
      parameter name: :id, in: :path, schema: { type: :string, format: :uuid }, required: true
      let(:insight) do
        family.insights.create!(
          insight_type: "idle_cash", priority: "medium", status: "active",
          title: "Idle cash", body: "Review available cash.",
          generated_at: Time.current, dedup_key: "api-docs-acknowledgment"
        )
      end
      let(:id) { insight.id }

      response "204", "insight acknowledged" do
        run_test!
      end
      response "401", "authentication required" do
        let(:"X-Api-Key") { "invalid-api-key" }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
      response "403", "write scope, member access or preview features required" do
        let(:api_key) do
          key = ApiKey.generate_secure_key
          ApiKey.create!(user: user, name: "API Docs Read Key", key: key, scopes: %w[read], source: "web")
        end
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
      response "404", "insight not found or not visible to the family" do
        let(:id) { SecureRandom.uuid }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end
end

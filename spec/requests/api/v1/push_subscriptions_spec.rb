# frozen_string_literal: true

require "swagger_helper"

RSpec.describe "API V1 Push Subscriptions", type: :request do
  before { allow(Rails.application.config).to receive(:app_mode).and_return("managed".inquiry) }

  let(:family) { Family.create!(name: "API Family") }
  let(:user) do
    family.users.create!(email: "push-api@example.com", password: "password123", ai_enabled: true)
  end
  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(user: user, name: "API Docs Key", key: key, scopes: %w[read_write], source: "web")
  end
  let(:"X-Api-Key") { api_key.plain_key }

  path "/api/v1/push_subscriptions" do
    post "Register an APNs device token" do
      description "Available only in hosted (managed) mode. Requires write scope."
      tags "Push Subscriptions"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :subscription, in: :body, required: true, schema: {
        type: :object,
        required: %w[token environment platform],
        properties: {
          token: { type: :string, maxLength: 2048, pattern: "^(?:[0-9a-fA-F]{2})+$" },
          environment: { type: :string, enum: %w[sandbox production] },
          platform: { type: :string, enum: %w[ios] }
        }
      }
      let(:subscription) { { token: "ab" * 32, environment: "sandbox", platform: "ios" } }

      response "403", "push unavailable in self-hosted mode or insufficient write scope" do
        before { allow(Rails.application.config).to receive(:app_mode).and_return("self_hosted".inquiry) }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "201", "token registered" do
        schema "$ref" => "#/components/schemas/PushSubscription"
        run_test!
      end


      response "422", "invalid or conflicting subscription" do
        schema "$ref" => "#/components/schemas/ErrorResponse"
        let(:subscription) { { token: "ab" * 32, environment: "staging", platform: "ios" } }

        run_test!
      end
    end
  end


  path "/api/v1/push_subscriptions/{id}" do
    parameter name: :id, in: :path, type: :string, required: true
    let(:subscription) do
      user.push_subscriptions.create!(
        token: "cd" * 32,
        environment: "sandbox",
        platform: "ios",
        last_registered_at: Time.current
      )
    end
    let(:id) { subscription.id }

    delete "Unregister an APNs device token" do
      description "Available only in hosted (managed) mode. Requires write scope."
      tags "Push Subscriptions"
      security [ { apiKeyAuth: [] } ]

      response "403", "push unavailable in self-hosted mode or insufficient write scope" do
        before { allow(Rails.application.config).to receive(:app_mode).and_return("self_hosted".inquiry) }
        produces "application/json"
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "204", "token unregistered" do
        run_test!
      end
    end
  end
end

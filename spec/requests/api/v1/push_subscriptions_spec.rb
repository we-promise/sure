# frozen_string_literal: true

require "swagger_helper"

RSpec.describe "API V1 Push Subscriptions", type: :request do
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
      tags "Push Subscriptions"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :subscription, in: :body, required: true, schema: {
        type: :object,
        required: %w[token environment platform],
        properties: {
          token: { type: :string },
          environment: { type: :string, enum: %w[sandbox production] },
          platform: { type: :string, enum: %w[ios] }
        }
      }
      let(:subscription) { { token: "ab" * 32, environment: "sandbox", platform: "ios" } }

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
      tags "Push Subscriptions"
      security [ { apiKeyAuth: [] } ]

      response "204", "token unregistered" do
        run_test!
      end
    end
  end
end

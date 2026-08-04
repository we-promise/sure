# frozen_string_literal: true

require "swagger_helper"

# Documentation-only spec. Behavioural coverage for this endpoint belongs in
# test/controllers/api/v1/ (Minitest). Use run_test! without assertions here so
# the generated OpenAPI document stays a faithful description of the API.
RSpec.describe "Api::V1::Sync", type: :request do
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
      email: "sync-trigger-api-user@example.com",
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

  let(:api_key_without_write_scope) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: "Read Only Docs Key",
      key: key,
      display_key: key,
      scopes: %w[read],
      source: "web"
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  path "/api/v1/sync" do
    post "Triggers a family sync" do
      description "Queues a sync for the authenticated user's family. The sync applies all active rules, syncs every account, and auto-matches transfers. Returns immediately with the queued sync record."
      tags "Syncs"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"

      response "202", "sync queued" do
        schema type: :object,
               properties: {
                 id: { type: :string, format: :uuid },
                 status: { type: :string },
                 syncable_type: { type: :string },
                 syncable_id: { type: :string, format: :uuid },
                 syncing_at: { type: :string, format: :"date-time", nullable: true },
                 completed_at: { type: :string, format: :"date-time", nullable: true },
                 window_start_date: { type: :string, format: :date, nullable: true },
                 window_end_date: { type: :string, format: :date, nullable: true },
                 message: { type: :string }
               },
               required: %w[id status]

        run_test!
      end

      response "401", "unauthorized" do
        schema "$ref" => "#/components/schemas/ErrorResponse"
        let(:'X-Api-Key') { nil }

        run_test!
      end

      response "403", "insufficient scope" do
        schema "$ref" => "#/components/schemas/ErrorResponse"
        let(:'X-Api-Key') { api_key_without_write_scope.plain_key }

        run_test!
      end
    end
  end
end

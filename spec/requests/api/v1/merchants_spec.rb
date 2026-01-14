# frozen_string_literal: true

require "swagger_helper"

RSpec.describe "Api::V1::Merchants", type: :request do
  let(:family) { Family.create!(name: "Test Family") }
  let(:user) do
    family.users.create!(
      email: "test@example.com",
      password: "password123",
      first_name: "Test",
      last_name: "User"
    )
  end

  let(:oauth_application) do
    Doorkeeper::Application.create!(
      name: "Test App",
      redirect_uri: "https://example.com/callback",
      scopes: "read read_write"
    )
  end

  let(:access_token) do
    Doorkeeper::AccessToken.create!(
      application: oauth_application,
      resource_owner_id: user.id,
      scopes: "read"
    )
  end

  let(:Authorization) { "Bearer #{access_token.token}" }

  # Create test merchants
  let!(:family_merchant) do
    family.merchants.create!(name: "Test Merchant", type: "FamilyMerchant")
  end

  let!(:account) do
    family.accounts.create!(
      name: "Test Account",
      balance: 1000,
      currency: "USD",
      accountable: Depository.new
    )
  end

  path "/api/v1/merchants" do
    get "List all merchants" do
      tags "Merchants"
      description "Returns all family merchants and provider merchants assigned to transactions"
      operationId "listMerchants"
      produces "application/json"
      security [{ bearerAuth: [] }]

      parameter name: :Authorization,
                in: :header,
                type: :string,
                required: true,
                description: "Bearer token"

      response "200", "merchants retrieved successfully" do
        schema type: :array,
               items: {
                 type: :object,
                 properties: {
                   id: { type: :string, format: :uuid },
                   name: { type: :string },
                   type: { type: :string, enum: %w[FamilyMerchant ProviderMerchant] },
                   created_at: { type: :string, format: "date-time" },
                   updated_at: { type: :string, format: "date-time" }
                 },
                 required: %w[id name type created_at updated_at]
               }

        run_test! do |response|
          merchants = JSON.parse(response.body)
          expect(merchants).to be_an(Array)
          expect(merchants.length).to be >= 1
          expect(merchants.first).to include("id", "name", "type")
        end
      end

      response "401", "unauthorized" do
        let(:Authorization) { "Bearer invalid_token" }

        run_test! do |response|
          expect(response).to have_http_status(:unauthorized)
        end
      end
    end
  end

  path "/api/v1/merchants/{id}" do
    get "Get a specific merchant" do
      tags "Merchants"
      description "Returns a single merchant by ID"
      operationId "getMerchant"
      produces "application/json"
      security [{ bearerAuth: [] }]

      parameter name: :Authorization,
                in: :header,
                type: :string,
                required: true,
                description: "Bearer token"

      parameter name: :id,
                in: :path,
                type: :string,
                format: :uuid,
                required: true,
                description: "Merchant ID"

      response "200", "merchant retrieved successfully" do
        schema type: :object,
               properties: {
                 id: { type: :string, format: :uuid },
                 name: { type: :string },
                 type: { type: :string },
                 created_at: { type: :string, format: "date-time" },
                 updated_at: { type: :string, format: "date-time" }
               },
               required: %w[id name type created_at updated_at]

        let(:id) { family_merchant.id }

        run_test! do |response|
          merchant = JSON.parse(response.body)
          expect(merchant["id"]).to eq(family_merchant.id)
          expect(merchant["name"]).to eq("Test Merchant")
        end
      end

      response "404", "merchant not found" do
        let(:id) { "00000000-0000-0000-0000-000000000000" }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end

      response "401", "unauthorized" do
        let(:Authorization) { "Bearer invalid_token" }
        let(:id) { family_merchant.id }

        run_test! do |response|
          expect(response).to have_http_status(:unauthorized)
        end
      end
    end
  end
end

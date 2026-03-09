# frozen_string_literal: true

require "swagger_helper"

RSpec.describe "API V1 Transaction Transfers", type: :request do
  let(:family) do
    Family.create!(
      name: "Transfer API Family",
      currency: "USD",
      locale: "en",
      date_format: "%m-%d-%Y"
    )
  end

  let(:user) do
    family.users.create!(
      email: "transfer-api-user@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: "Transfer API Docs Key",
      key: key,
      scopes: %w[read_write],
      source: "web"
    )
  end

  let(:"X-Api-Key") { api_key.plain_key }

  let(:checking_account) do
    Account.create!(
      family: family,
      name: "Checking",
      balance: 5000,
      currency: "USD",
      accountable: Depository.create!
    )
  end

  let(:credit_card_account) do
    Account.create!(
      family: family,
      name: "Credit Card",
      balance: 500,
      currency: "USD",
      accountable: CreditCard.create!
    )
  end

  let(:outflow_entry) do
    checking_account.entries.create!(
      name: "Credit card payment",
      date: Date.current,
      amount: 200.00,
      currency: "USD",
      entryable: Transaction.new
    )
  end

  let(:inflow_entry) do
    credit_card_account.entries.create!(
      name: "Payment received",
      date: Date.current,
      amount: -200.00,
      currency: "USD",
      entryable: Transaction.new
    )
  end

  let(:transaction) { outflow_entry.transaction }
  let(:other_transaction) { inflow_entry.transaction }

  path "/api/v1/transactions/{transaction_id}/transfer" do
    patch "Link transaction as a transfer" do
      tags "Transactions"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"

      parameter name: :transaction_id, in: :path, type: :string, format: :uuid,
                required: true, description: "ID of the transaction to link"

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          transfer: {
            type: :object,
            required: %w[other_transaction_id],
            properties: {
              other_transaction_id: {
                type: :string,
                format: :uuid,
                description: "ID of the counterpart transaction to link as a transfer"
              }
            }
          }
        },
        required: %w[transfer]
      }

      response "200", "transfer linked successfully" do
        schema "$ref" => "#/components/schemas/Transaction"

        let(:transaction_id) { transaction.id }
        let(:body) { { transfer: { other_transaction_id: other_transaction.id } } }

        run_test!
      end

      response "404", "transaction not found" do
        schema "$ref" => "#/components/schemas/ErrorResponse"

        let(:transaction_id) { "00000000-0000-0000-0000-000000000000" }
        let(:body) { { transfer: { other_transaction_id: other_transaction.id } } }

        run_test!
      end

      response "422", "validation failed" do
        schema "$ref" => "#/components/schemas/ErrorResponse"

        let(:transaction_id) { transaction.id }
        let(:body) { { transfer: {} } }

        run_test!
      end

      response "401", "unauthorized" do
        schema "$ref" => "#/components/schemas/ErrorResponse"

        let(:"X-Api-Key") { "invalid-key" }
        let(:transaction_id) { transaction.id }
        let(:body) { { transfer: { other_transaction_id: other_transaction.id } } }

        run_test!
      end
    end
  end
end

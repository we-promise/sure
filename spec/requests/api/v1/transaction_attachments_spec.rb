# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Transaction Attachments', type: :request do
  let(:family) { Family.create!(name: 'API Family', currency: 'USD', locale: 'en', date_format: '%m-%d-%Y') }
  let(:user) do
    family.users.create!(email: 'api-user@example.com', password: 'password123', password_confirmation: 'password123', role: 'admin')
  end
  let(:api_key) do
    ApiKey.create!(user: user, name: 'API Docs Key', key: ApiKey.generate_secure_key, scopes: %w[read], source: 'mobile')
  end
  let(:'X-Api-Key') { api_key.plain_key }
  let(:account) do
    Account.create!(family: family, owner: user, name: 'Checking', balance: 1000, currency: 'USD', accountable: Depository.new)
  end
  let(:entry) do
    account.entries.create!(name: 'Corner Grocer', date: Date.current, amount: 50, currency: 'USD', entryable: Transaction.new)
  end
  let(:transaction_id) { entry.entryable.id }
  let(:attachment) do
    entry.entryable.attachments.attach(io: Rails.root.join('test/fixtures/files/receipts/rotated.jpg').open,
                                       filename: 'receipt.jpg', content_type: 'image/jpeg')
    entry.entryable.attachments.first
  end

  path '/api/v1/transactions/{transaction_id}/attachments/{id}' do
    parameter name: :transaction_id, in: :path, type: :string, format: :uuid, required: true
    parameter name: :id, in: :path, type: :string, format: :uuid, required: true
    parameter name: :variant, in: :query, required: false, schema: { type: :string, enum: %w[thumbnail] },
              description: 'thumbnail returns a small preview of an image attachment'

    get 'Download a transaction attachment' do
      description 'Returns the file attached to a transaction, such as a receipt photo, using the API credentials. ' \
                  'Transaction JSON links each attachment here.'
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      produces 'image/jpeg', 'image/png', 'image/webp', 'application/pdf', 'application/json'

      response '200', 'attachment file' do
        schema type: :string, format: :binary
        let(:id) { attachment.id }
        run_test!
      end

      response '404', 'transaction or attachment not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:id) { SecureRandom.uuid }
        run_test!
      end
    end
  end
end

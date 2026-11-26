# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Receipts', type: :request do
  let(:family) do
    Family.create!(name: 'API Family', currency: 'USD', locale: 'en', date_format: '%m-%d-%Y')
  end
  let(:user) do
    family.users.create!(
      email: 'api-user@example.com',
      password: 'password123',
      password_confirmation: 'password123',
      role: 'admin',
      preferences: { 'preview_features_enabled' => true }
    )
  end
  let(:api_key) do
    ApiKey.create!(user: user, name: 'API Docs Key', key: ApiKey.generate_secure_key, scopes: %w[read_write], source: 'web')
  end
  let(:'X-Api-Key') { api_key.plain_key }
  let(:account) do
    Account.create!(family: family, owner: user, name: 'Test Checking', balance: 1000, currency: 'USD', accountable: Depository.new)
  end

  before do
    allow(ReceiptScan).to receive(:extraction_available?).and_return(true)
  end

  def receipt_file
    Rack::Test::UploadedFile.new(Rails.root.join('test/fixtures/files/receipts/rotated.jpg'), 'image/jpeg')
  end

  path '/api/v1/receipts' do
    post 'Upload a receipt' do
      description 'Uploads up to 5 photos, or one PDF on its own, of one receipt, bill or invoice (10 MB each; JPEG, PNG, WebP, HEIC, PDF) ' \
                  'for an account the caller can write to. A "Processing receipt…" transaction is created at once; the receipt ' \
                  'is then read in the background, the transaction filled in and split by category, or the receipt attached to ' \
                  'an existing bank transaction for the same payment. Poll the receipt for its status.'
      tags 'Receipts'
      security [ { apiKeyAuth: [] } ]
      consumes 'multipart/form-data'
      produces 'application/json'

      # The first form parameter's schema describes the whole multipart body.
      parameter name: :files, in: :formData, required: true,
                description: 'Receipt photos or PDF, as files[]',
                schema: {
                  type: :object,
                  required: %w[account_id files[]],
                  properties: {
                    account_id: { type: :string, format: :uuid, description: 'Account the receipt was paid from (needs write access to it)' },
                    'files[]': {
                      type: :array, minItems: 1, maxItems: 5,
                      description: 'Up to 5 photos, or one PDF, of one receipt, 10 MB each (JPEG, PNG, WebP, HEIC, PDF). Send each file as a files[] part.',
                      items: { type: :string, format: :binary }
                    }
                  }
                }
      parameter name: :account_id, in: :formData, required: true,
                description: 'Account the receipt was paid from (needs write access to it)',
                schema: { type: :string, format: :uuid }

      response '202', 'receipt accepted for processing' do
        schema '$ref' => '#/components/schemas/ReceiptScan'
        let(:account_id) { account.id }
        let(:files) { [ receipt_file ] }
        run_test!
      end

      response '403', 'receipt scanning is not available: preview features off, or no AI provider that can read images' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        before { allow(ReceiptScan).to receive(:extraction_available?).and_return(false) }
        let(:account_id) { account.id }
        let(:files) { [ receipt_file ] }
        run_test!
      end

      response '404', 'account not found or not writable' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:account_id) { SecureRandom.uuid }
        let(:files) { [ receipt_file ] }
        run_test!
      end

      response '422', 'invalid files' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:account_id) { account.id }
        let(:files) { Array.new(6) { receipt_file } }
        run_test!
      end
    end
  end

  path '/api/v1/receipts/{id}' do
    parameter name: :id, in: :path, type: :string, format: :uuid, required: true

    get 'Retrieve a receipt' do
      tags 'Receipts'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'receipt' do
        schema '$ref' => '#/components/schemas/ReceiptScan'
        let(:id) { ReceiptScan.create!(family: family, user: user, account: account).id }
        run_test!
      end

      response '404', 'not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:id) { SecureRandom.uuid }
        run_test!
      end
    end
  end
end

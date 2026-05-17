# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'BankData imports API', type: :request do
  let(:family) { Family.create!(name: 'BankData API Family', currency: 'EUR', locale: 'en', date_format: '%Y-%m-%d') }
  let(:user) do
    family.users.create!(
      email: 'bankdata-api-user@example.com',
      password: 'password123',
      password_confirmation: 'password123'
    )
  end
  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(user: user, name: 'BankData API Docs Key', key: key, scopes: %w[read_write], source: 'web')
  end
  let(:'X-Api-Key') { api_key.plain_key }
  let(:account) do
    Account.create!(
      family: family,
      name: 'Betaal',
      balance: 0,
      currency: 'EUR',
      accountable: Depository.create!
    )
  end
  let(:payload) do
    JSON.parse(Rails.root.join('test/fixtures/files/bankdata_import_payload.json').read).tap do |current|
      current['account_mappings'][0]['sure_account_id'] = account.id
    end
  end

  path '/api/v1/bankdata/imports/preview' do
    post 'Preview a BankData append-only import' do
      tags 'BankData Imports'
      consumes 'application/json'
      produces 'application/json'
      security [ apiKeyAuth: [] ]
      parameter name: :'X-Api-Key', in: :header, type: :string, required: true
      parameter name: :payload, in: :body, schema: { '$ref' => '#/components/schemas/BankdataImportRequest' }

      response '200', 'preview summary' do
        schema '$ref' => '#/components/schemas/BankdataImportSummary'
        run_test!
      end
    end
  end

  path '/api/v1/bankdata/imports' do
    post 'Run a BankData append-only import' do
      tags 'BankData Imports'
      consumes 'application/json'
      produces 'application/json'
      security [ apiKeyAuth: [] ]
      parameter name: :'X-Api-Key', in: :header, type: :string, required: true
      parameter name: :payload, in: :body, schema: { '$ref' => '#/components/schemas/BankdataImportRequest' }

      response '201', 'import summary' do
        schema '$ref' => '#/components/schemas/BankdataImportSummary'
        run_test!
      end

      response '201', 'imports uncategorized SQL rows for later Sure Rules categorization' do
        schema '$ref' => '#/components/schemas/BankdataImportSummary'
        let(:payload) do
          JSON.parse(Rails.root.join('test/fixtures/files/bankdata_import_uncategorized_payload.json').read).tap do |current|
            current['account_mappings'][0]['sure_account_id'] = account.id
          end
        end

        run_test!
      end
    end
  end
end

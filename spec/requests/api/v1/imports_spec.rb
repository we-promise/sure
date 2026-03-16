# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Imports', type: :request do
  let(:family) do
    Family.create!(
      name: 'API Family',
      currency: 'USD',
      locale: 'en',
      date_format: '%m-%d-%Y'
    )
  end

  let(:user) do
    family.users.create!(
      email: 'api-user@example.com',
      password: 'password123',
      password_confirmation: 'password123'
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'API Docs Key',
      key: key,
      scopes: %w[read_write],
      source: 'web'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  let(:account) do
    Account.create!(
      family: family,
      name: 'Test Checking',
      balance: 1000,
      currency: 'USD',
      accountable: Depository.new
    )
  end

  let!(:pending_import) do
    family.imports.create!(
      type: 'TransactionImport',
      status: 'pending',
      account: account,
      raw_file_str: "date,amount,name\n01/01/2024,10.00,Test Transaction"
    )
  end

  let!(:complete_import) do
    family.imports.create!(
      type: 'TransactionImport',
      status: 'complete',
      account: account,
      raw_file_str: "date,amount,name\n01/02/2024,20.00,Another Transaction"
    )
  end

  path '/api/v1/imports' do
    get 'List imports' do
      description 'List all imports for the user\'s family with pagination and filtering.'
      tags 'Imports'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false,
                description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false,
                description: 'Items per page (default: 25, max: 100)'
      parameter name: :status, in: :query, required: false,
                description: 'Filter by status',
                schema: { type: :string, enum: %w[pending complete importing reverting revert_failed failed] }
      parameter name: :type, in: :query, required: false,
                description: 'Filter by import type',
                schema: { type: :string, enum: %w[TransactionImport TradeImport AccountImport MintImport CategoryImport RuleImport] }

      response '200', 'imports listed' do
        schema '$ref' => '#/components/schemas/ImportCollection'

        run_test!
      end

      response '200', 'imports filtered by status' do
        schema '$ref' => '#/components/schemas/ImportCollection'

        let(:status) { 'pending' }

        run_test!
      end

      response '200', 'imports filtered by type' do
        schema '$ref' => '#/components/schemas/ImportCollection'

        let(:type) { 'TransactionImport' }

        run_test!
      end
    end

    post 'Create import' do
      description 'Create a new import from raw CSV content.'
      tags 'Imports'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          raw_file_content: {
            type: :string,
            description: 'The raw CSV content as a string'
          },
          type: {
            type: :string,
            enum: %w[TransactionImport TradeImport AccountImport MintImport CategoryImport RuleImport],
            description: 'Import type (defaults to TransactionImport)'
          },
          account_id: {
            type: :string,
            format: :uuid,
            description: 'Account ID to import into'
          },
          publish: {
            type: :string,
            description: 'Set to "true" to automatically queue for processing if configuration is valid'
          },
          date_col_label: {
            type: :string,
            description: 'Header name for the date column'
          },
          amount_col_label: {
            type: :string,
            description: 'Header name for the amount column'
          },
          name_col_label: {
            type: :string,
            description: 'Header name for the transaction name column'
          },
          category_col_label: {
            type: :string,
            description: 'Header name for the category column'
          },
          tags_col_label: {
            type: :string,
            description: 'Header name for the tags column'
          },
          notes_col_label: {
            type: :string,
            description: 'Header name for the notes column'
          },
          date_format: {
            type: :string,
            description: 'Date format pattern (e.g., "%m/%d/%Y")'
          },
          number_format: {
            type: :string,
            enum: [ '1,234.56', '1.234,56', '1 234,56', '1,234' ],
            description: 'Number format for parsing amounts'
          },
          signage_convention: {
            type: :string,
            enum: %w[inflows_positive inflows_negative],
            description: 'How to interpret positive/negative amounts'
          },
          col_sep: {
            type: :string,
            enum: [ ',', ';' ],
            description: 'Column separator'
          }
        }
      }

      response '201', 'import created' do
        schema '$ref' => '#/components/schemas/ImportResponse'

        let(:body) do
          {
            raw_file_content: "date,amount,name\n01/15/2024,50.00,New Transaction",
            type: 'TransactionImport',
            account_id: account.id,
            date_col_label: 'date',
            amount_col_label: 'amount',
            name_col_label: 'name'
          }
        end

        run_test!
      end

      response '422', 'validation error - file too large' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            raw_file_content: 'x' * (11 * 1024 * 1024), # 11MB, exceeds MAX_CSV_SIZE
            type: 'TransactionImport'
          }
        end

        run_test!
      end
    end
  end

  path '/api/v1/imports/{id}' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Import ID'

    get 'Retrieve an import' do
      description 'Retrieve detailed information about a specific import, including configuration and row statistics.'
      tags 'Imports'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { pending_import.id }

      response '200', 'import retrieved' do
        schema '$ref' => '#/components/schemas/ImportResponse'

        run_test!
      end

      response '404', 'import not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end

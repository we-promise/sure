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

  let(:api_key_without_read_scope) do
    key = ApiKey.generate_secure_key
    ApiKey.new(
      user: user,
      name: 'No Read Docs Key',
      key: key,
      scopes: %w[write],
      source: 'web'
    ).tap { |api_key| api_key.save!(validate: false) }
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

  let!(:import_row) do
    pending_import.rows.create!(
      source_row_number: 1,
      date: '01/01/2024',
      amount: '10.00',
      currency: 'USD',
      name: 'Test Transaction'
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
                schema: { type: :string, enum: %w[TransactionImport TradeImport AccountImport MintImport CategoryImport RuleImport SureImport] }

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
      description 'Create a new import from raw CSV content, inline Sure NDJSON content, or an uploaded Sure NDJSON file.'
      tags 'Imports'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json', 'multipart/form-data'
      produces 'application/json'

      parameter name: :body, in: :body, required: false, schema: {
        type: :object,
        properties: {
          raw_file_content: {
            type: :string,
            description: 'Raw CSV or Sure NDJSON content as a string. Required for SureImport unless a multipart file is uploaded.'
          },
          type: {
            type: :string,
            enum: %w[TransactionImport TradeImport AccountImport MintImport CategoryImport RuleImport SureImport],
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
            description: 'CSV imports only. Header name for the date column'
          },
          amount_col_label: {
            type: :string,
            description: 'CSV imports only. Header name for the amount column'
          },
          name_col_label: {
            type: :string,
            description: 'CSV imports only. Header name for the transaction name column'
          },
          category_col_label: {
            type: :string,
            description: 'CSV imports only. Header name for the category column'
          },
          tags_col_label: {
            type: :string,
            description: 'CSV imports only. Header name for the tags column'
          },
          notes_col_label: {
            type: :string,
            description: 'CSV imports only. Header name for the notes column'
          },
          account_col_label: {
            type: :string,
            description: 'CSV imports only. Header name for the account column when importing rows across multiple accounts'
          },
          qty_col_label: {
            type: :string,
            description: 'CSV trade imports only. Header name for the quantity column'
          },
          ticker_col_label: {
            type: :string,
            description: 'CSV trade imports only. Header name for the ticker column'
          },
          price_col_label: {
            type: :string,
            description: 'CSV trade imports only. Header name for the price column'
          },
          entity_type_col_label: {
            type: :string,
            description: 'CSV imports only. Header name for the entity type column'
          },
          currency_col_label: {
            type: :string,
            description: 'CSV imports only. Header name for the currency column'
          },
          exchange_operating_mic_col_label: {
            type: :string,
            description: 'CSV trade imports only. Header name for the exchange operating MIC column'
          },
          external_id_col_label: {
            type: :string,
            description: 'Header name for the external ID column (used for deduplication on re-import)'
          },
          date_format: {
            type: :string,
            description: 'CSV imports only. Date format pattern (e.g., "%m/%d/%Y")'
          },
          number_format: {
            type: :string,
            enum: [ '1,234.56', '1.234,56', '1 234,56', '1,234' ],
            description: 'CSV imports only. Number format for parsing amounts'
          },
          signage_convention: {
            type: :string,
            enum: %w[inflows_positive inflows_negative],
            description: 'CSV imports only. How to interpret positive/negative amounts'
          },
          col_sep: {
            type: :string,
            enum: [ ',', ';' ],
            description: 'CSV imports only. Column separator'
          },
          amount_type_strategy: {
            type: :string,
            enum: %w[signed_amount custom_column],
            description: 'CSV imports only. Amount parsing strategy'
          },
          amount_type_inflow_value: {
            type: :string,
            description: 'CSV imports only. Column value that marks an amount as an inflow when using custom_column strategy'
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
        schema oneOf: [
          { '$ref' => '#/components/schemas/ErrorResponse' },
          { '$ref' => '#/components/schemas/ErrorResponseWithImportId' }
        ]

        let(:body) do
          {
            raw_file_content: 'x' * (11 * 1024 * 1024), # 11MB, exceeds MAX_CSV_SIZE
            type: 'TransactionImport'
          }
        end

        run_test!
      end

      response '500', 'import uploaded but publish enqueue failed' do
        schema '$ref' => '#/components/schemas/ErrorResponseWithImportId'

        let(:body) do
          {
            raw_file_content: { type: 'Account', data: { id: 'account_1', name: 'Checking' } }.to_json,
            type: 'SureImport',
            publish: 'true'
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

  path '/api/v1/imports/{id}/rows' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Import ID'

    get 'List import row diagnostics' do
      description 'List sanitized import rows with validation errors and mapping resolution state.'
      tags 'Imports'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false,
                description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false,
                description: 'Items per page (default: 25, max: 100)'

      let(:id) { pending_import.id }

      response '200', 'import rows listed' do
        schema '$ref' => '#/components/schemas/ImportRowDiagnosticCollection'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'insufficient scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '404', 'import not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end

      response '500', 'internal server error' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before do
          allow_any_instance_of(Import::Row).to receive(:valid?).and_raise(StandardError, 'validation down')
        end

        run_test!
      end
    end
  end
end

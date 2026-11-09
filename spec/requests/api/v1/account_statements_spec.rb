# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Account Statements', type: :request do
  let(:family) do
    Family.create!(name: 'API Family', currency: 'USD', locale: 'en', date_format: '%m-%d-%Y')
  end
  let(:user) do
    family.users.create!(
      email: 'api-user@example.com',
      password: 'password123',
      password_confirmation: 'password123',
      role: 'admin'
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
      owner: user,
      name: 'Test Checking',
      balance: 1000,
      currency: 'USD',
      accountable: Depository.new
    )
  end

  def statement_file(content: "date,amount\n2024-01-01,1\n", filename: 'statement_2024-01.csv')
    Rack::Test::UploadedFile.new(StringIO.new(content), 'text/csv', true, original_filename: filename)
  end

  let!(:statement) do
    AccountStatement.create_from_upload!(
      family: user.family,
      account: account,
      file: statement_file(content: "date,amount\n2024-02-01,2\n", filename: 'statement_2024-02.csv')
    )
  end

  path '/api/v1/account_statements' do
    get 'List statements in the Statement Vault' do
      description 'Lists statements the caller can see: unlinked statements and statements linked to accounts shared with them. Requires an admin or member.'
      tags 'Account Statements'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      parameter name: :account_id, in: :query, type: :string, format: :uuid, required: false,
                description: 'Only statements linked to this account'
      parameter name: :review_status, in: :query, required: false,
                schema: { type: :string, enum: %w[unmatched linked rejected] }
      parameter name: :content_sha256, in: :query, type: :string, required: false,
                description: 'Find the statement for a file by its SHA-256 (hex)'
      parameter name: :start_date, in: :query, type: :string, format: :date, required: false,
                description: 'Only statements whose period ends on or after this date'
      parameter name: :end_date, in: :query, type: :string, format: :date, required: false,
                description: 'Only statements whose period starts on or before this date'
      parameter name: :page, in: :query, type: :integer, required: false, description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false, description: 'Items per page (default: 25, max: 100)'

      response '200', 'statements listed' do
        schema '$ref' => '#/components/schemas/AccountStatementCollection'
        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { nil }
        run_test!
      end

      response '422', 'invalid filter' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:start_date) { 'not-a-date' }
        run_test!
      end
    end

    post 'Upload a statement to the Statement Vault' do
      description 'Stores a PDF, CSV or XLSX statement (max 25 MB). With account_id the statement is linked to that account ' \
                  '(needs write access to it); without it the vault suggests a match to confirm in the app. ' \
                  'The vault stores each file once: uploading the same file again returns the existing statement with meta.duplicate = true. ' \
                  'Statements are archived only; no transactions are imported.'
      tags 'Account Statements'
      security [ { apiKeyAuth: [] } ]
      consumes 'multipart/form-data'
      produces 'application/json'

      parameter name: :file, in: :formData, required: true,
                description: 'Statement file (.pdf, .csv or .xlsx)',
                schema: {
                  type: :object,
                  required: [ 'file' ],
                  properties: {
                    file: { type: :string, format: :binary },
                    account_id: { type: :string, format: :uuid, description: 'Account to link the statement to' }
                  }
                }

      response '201', 'statement stored' do
        schema '$ref' => '#/components/schemas/AccountStatementResponse'
        let(:file) { statement_file }
        run_test!
      end

      response '200', 'file already in the vault' do
        schema '$ref' => '#/components/schemas/AccountStatementResponse'
        let(:file) { statement_file(content: "date,amount\n2024-02-01,2\n") }
        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { nil }
        let(:file) { statement_file }
        run_test!
      end

      response '422', 'missing or invalid file' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:file) { nil }
        run_test!
      end
    end
  end

  path '/api/v1/account_statements/{id}' do
    parameter name: :id, in: :path, type: :string, format: :uuid, required: true

    get 'Show a statement' do
      tags 'Account Statements'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'statement found' do
        schema '$ref' => '#/components/schemas/AccountStatementResponse'
        let(:id) { statement.id }
        run_test!
      end

      response '404', 'statement not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:id) { SecureRandom.uuid }
        run_test!
      end
    end
  end
end

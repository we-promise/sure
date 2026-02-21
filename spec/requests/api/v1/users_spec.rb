# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Users', type: :request do
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

  path '/api/v1/users/reset' do
    delete 'Reset account' do
      tags 'Users'
      description 'Resets all financial data (accounts, categories, merchants, tags, etc.) ' \
                  'for the current user\'s family while keeping the user account intact. ' \
                  'The reset runs asynchronously in the background.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'account reset initiated' do
        schema '$ref' => '#/components/schemas/SuccessMessage'

        run_test!
      end

      response '401', 'unauthorized' do
        let(:'X-Api-Key') { 'invalid-key' }

        run_test!
      end

      response '403', 'insufficient scope' do
        let(:api_key) do
          key = ApiKey.generate_secure_key
          ApiKey.create!(
            user: user,
            name: 'Read Only Key',
            key: key,
            scopes: %w[read],
            source: 'web'
          )
        end

        run_test!
      end
    end
  end

  path '/api/v1/users/me' do
    delete 'Delete account' do
      tags 'Users'
      description 'Permanently deactivates the current user account and all associated data. ' \
                  'This action cannot be undone.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'account deleted' do
        schema '$ref' => '#/components/schemas/SuccessMessage'

        run_test!
      end

      response '401', 'unauthorized' do
        let(:'X-Api-Key') { 'invalid-key' }

        run_test!
      end

      response '403', 'insufficient scope' do
        let(:api_key) do
          key = ApiKey.generate_secure_key
          ApiKey.create!(
            user: user,
            name: 'Read Only Key',
            key: key,
            scopes: %w[read],
            source: 'web'
          )
        end

        run_test!
      end

      response '422', 'deactivation failed' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before do
          allow_any_instance_of(User).to receive(:deactivate).and_return(false)
          allow_any_instance_of(User).to receive(:errors).and_return(
            double(full_messages: [ 'Cannot deactivate admin with other users' ])
          )
        end

        run_test!
      end
    end
  end
end

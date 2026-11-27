# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Version', type: :request do
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

  path '/api/v1/version' do
    get 'Get the running Sure version' do
      tags 'Version'
      description 'Requires read or read_write access. Operators may explicitly enable anonymous access with PUBLIC_VERSION_ENDPOINT=true. Responses are not cacheable. Supplied credentials are still validated in public mode.'
      security [ { apiKeyAuth: [] }, { oauth2: [ 'read' ] } ]
      produces 'application/json'

      response '200', 'running version' do
        schema '$ref' => '#/components/schemas/Version'
        run_test!
      end

      response '401', 'missing or invalid credentials (default configuration)' do
        let(:'X-Api-Key') { nil }
        run_test!
      end

      response '403', 'insufficient scope' do
        before { api_key.update_columns(scopes: []) }
        run_test!
      end
    end
  end
end

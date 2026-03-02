# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Auth', type: :request do
  path '/api/v1/auth/signup' do
    post 'Sign up a new user' do
      tags 'Auth'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          user: {
            type: :object,
            properties: {
              email: { type: :string, format: :email, description: 'User email address' },
              password: { type: :string, description: 'Password (min 8 chars, mixed case, number, special char)' },
              first_name: { type: :string },
              last_name: { type: :string }
            },
            required: %w[email password]
          },
          device: {
            type: :object,
            properties: {
              device_id: { type: :string, description: 'Unique device identifier' },
              device_name: { type: :string, description: 'Human-readable device name' },
              device_type: { type: :string, description: 'Device type (e.g. ios, android)' },
              os_version: { type: :string },
              app_version: { type: :string }
            },
            required: %w[device_id device_name device_type os_version app_version]
          },
          invite_code: { type: :string, nullable: true, description: 'Invite code (required when invites are enforced)' }
        },
        required: %w[user device]
      }

      let(:valid_device) do
        { device_id: SecureRandom.uuid, device_name: 'TestDevice', device_type: 'ios', os_version: '17.0', app_version: '1.0.0' }
      end

      response '201', 'user created' do
        schema type: :object,
               properties: {
                 access_token: { type: :string },
                 refresh_token: { type: :string },
                 token_type: { type: :string },
                 expires_in: { type: :integer },
                 created_at: { type: :integer },
                 user: {
                   type: :object,
                   properties: {
                     id: { type: :string, format: :uuid },
                     email: { type: :string },
                     first_name: { type: :string, nullable: true },
                     last_name: { type: :string, nullable: true }
                   }
                 }
               }

        let(:body) do
          unique_email = "user_#{SecureRandom.hex(6)}@example.com"
          { user: { email: unique_email, password: 'Password1!', first_name: 'Test', last_name: 'User' }, device: valid_device }
        end

        run_test!
      end

      response '422', 'validation error' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          { user: { email: 'bad@example.com', password: 'weak' }, device: valid_device }
        end

        run_test!
      end

      response '403', 'invite code required or invalid' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before { allow(ENV).to receive(:[]).and_call_original }
        before { allow(ENV).to receive(:[]).with('REQUIRE_INVITE_CODE').and_return('true') }

        let(:body) do
          { user: { email: 'noinvite@example.com', password: 'Password1!' }, device: valid_device }
        end

        run_test!
      end
    end
  end

  path '/api/v1/auth/login' do
    post 'Log in with email and password' do
      tags 'Auth'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          email: { type: :string, format: :email },
          password: { type: :string },
          otp_code: { type: :string, nullable: true, description: 'TOTP code if MFA is enabled' },
          device: {
            type: :object,
            properties: {
              device_id: { type: :string },
              device_name: { type: :string },
              device_type: { type: :string },
              os_version: { type: :string },
              app_version: { type: :string }
            },
            required: %w[device_id device_name device_type os_version app_version]
          }
        },
        required: %w[email password device]
      }

      let!(:login_family) { Family.create!(name: 'LoginFamily') }
      let!(:login_user) { User.create!(family: login_family, email: 'login_test@example.com', password: 'Password1!') }

      response '200', 'login successful' do
        before do
          # MobileDevice caches shared_oauth_application in a class ivar; reset to avoid FK issues across transactional tests
          MobileDevice.instance_variable_set(:@shared_oauth_application, nil)
          MobileDevice.shared_oauth_application
        end
        schema type: :object,
               properties: {
                 access_token: { type: :string },
                 refresh_token: { type: :string },
                 token_type: { type: :string },
                 expires_in: { type: :integer },
                 created_at: { type: :integer },
                 user: {
                   type: :object,
                   properties: {
                     id: { type: :string, format: :uuid },
                     email: { type: :string },
                     first_name: { type: :string, nullable: true },
                     last_name: { type: :string, nullable: true }
                   }
                 }
               }

        let(:body) do
          { email: 'login_test@example.com', password: 'Password1!', device: { device_id: 'dev-login-200', device_name: 'iPhone', device_type: 'ios', os_version: '17.0', app_version: '1.0.0' } }
        end

        run_test!
      end

      response '401', 'invalid credentials or MFA required' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          { email: 'nobody@example.com', password: 'wrongpassword', device: { device_id: SecureRandom.uuid, device_name: 'T', device_type: 'ios', os_version: '17.0', app_version: '1.0.0' } }
        end

        run_test!
      end
    end
  end

  path '/api/v1/auth/sso_exchange' do
    post 'Exchange mobile SSO authorization code for tokens' do
      tags 'Auth'
      consumes 'application/json'
      produces 'application/json'
      description 'Exchanges a one-time authorization code (received via deep link after mobile SSO) for OAuth tokens. The code is single-use and expires after 5 minutes.'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          code: { type: :string, description: 'One-time authorization code from mobile SSO callback' }
        },
        required: %w[code]
      }

      response '200', 'tokens issued' do
        schema type: :object,
               properties: {
                 access_token: { type: :string },
                 refresh_token: { type: :string },
                 token_type: { type: :string },
                 expires_in: { type: :integer },
                 created_at: { type: :integer },
                 user: {
                   type: :object,
                   properties: {
                     id: { type: :string, format: :uuid },
                     email: { type: :string },
                     first_name: { type: :string, nullable: true },
                     last_name: { type: :string, nullable: true }
                   }
                 }
               }

        let(:sso_code) { "sso_#{SecureRandom.hex(8)}" }
        let(:body) { { code: sso_code } }

        before do
          Rails.cache.write("mobile_sso:#{sso_code}", {
            access_token: 'tok', refresh_token: 'ref', token_type: 'Bearer',
            expires_in: 7200, created_at: Time.now.to_i,
            user_id: SecureRandom.uuid, user_email: 'sso@example.com',
            user_first_name: 'SSO', user_last_name: 'User'
          })
        end
      end

      response '401', 'invalid or expired code' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { code: 'invalid-code-xyz' } }

        run_test!
      end
    end
  end

  path '/api/v1/auth/refresh' do
    post 'Refresh an access token' do
      tags 'Auth'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          refresh_token: { type: :string, description: 'The refresh token from a previous login or refresh' },
          device: {
            type: :object,
            properties: {
              device_id: { type: :string }
            },
            required: %w[device_id]
          }
        },
        required: %w[refresh_token device]
      }

      let!(:ref_family) { Family.create!(name: 'RefFamily') }
      let!(:ref_user)   { User.create!(family: ref_family, email: 'ref@example.com', password: 'Password1!') }
      let!(:ref_app)    { Doorkeeper::Application.create!(name: 'RefApp', redirect_uri: 'urn:ietf:wg:oauth:2.0:oob', scopes: 'read write') }
      let!(:ref_token) do
        Doorkeeper::AccessToken.create!(
          application: ref_app,
          resource_owner_id: ref_user.id,
          expires_in: 30.days.to_i,
          scopes: 'read write',
          use_refresh_token: true
        )
      end

      response '200', 'token refreshed' do
        schema type: :object,
               properties: {
                 access_token: { type: :string },
                 refresh_token: { type: :string },
                 token_type: { type: :string },
                 expires_in: { type: :integer },
                 created_at: { type: :integer }
               }

        let(:body) { { refresh_token: ref_token.refresh_token, device: { device_id: 'dev-ref-ok' } } }

        run_test!
      end

      response '401', 'invalid refresh token' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { refresh_token: 'totally-invalid-refresh-token', device: { device_id: 'dev-x' } } }

        run_test!
      end

      response '400', 'missing refresh token' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { device: { device_id: 'dev-x' } } }

        run_test!
      end
    end
  end
end

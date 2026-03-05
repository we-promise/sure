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

      response '201', 'user created' do
        let(:body) do
          {
            user: {
              email: 'new.user@example.com',
              password: 'Str0ngP@ssword!',
              first_name: 'New',
              last_name: 'User'
            },
            device: {
              device_id: 'device-123',
              device_name: 'Test iPhone',
              device_type: 'ios',
              os_version: '17.0',
              app_version: '1.0.0'
            },
            invite_code: nil
          }
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
                     first_name: { type: :string },
                     last_name: { type: :string },
                     ui_layout: { type: :string, enum: %w[dashboard intro] },
                     ai_enabled: { type: :boolean }
                   }
                 }
               }
        run_test!
      end

      response '422', 'validation error' do
        let(:body) do
          {
            user: {
              email: 'bad.user@example.com',
              password: 'weak'
            },
            device: {
              device_id: 'device-123',
              device_name: 'Test iPhone',
              device_type: 'ios',
              os_version: '17.0',
              app_version: '1.0.0'
            },
            invite_code: nil
          }
        end

        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end

      response '403', 'invite code required or invalid' do
        let(:body) do
          {
            user: {
              email: 'invite.user@example.com',
              password: 'Str0ngP@ssword!'
            },
            device: {
              device_id: 'device-123',
              device_name: 'Test iPhone',
              device_type: 'ios',
              os_version: '17.0',
              app_version: '1.0.0'
            },
            invite_code: 'invalid-code'
          }
        end

        schema '$ref' => '#/components/schemas/ErrorResponse'
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

      response '200', 'login successful' do
        before do
          # MobileDevice memoizes the Doorkeeper application; reset between specs to avoid FK issues
          MobileDevice.instance_variable_set(:@shared_oauth_application, nil)
        end

        let!(:user_record) do
          family = Family.create!
          User.create!(
            family: family,
            role: 'member',
            email: 'login.user@example.com',
            password: 'Str0ngP@ssword!',
            first_name: 'Login',
            last_name: 'User'
          )
        end
        let(:body) do
          {
            email: user_record.email,
            password: 'Str0ngP@ssword!',
            device: {
              device_id: 'device-123',
              device_name: 'Test iPhone',
              device_type: 'ios',
              os_version: '17.0',
              app_version: '1.0.0'
            }
          }
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
                     first_name: { type: :string },
                     last_name: { type: :string },
                     ui_layout: { type: :string, enum: %w[dashboard intro] },
                     ai_enabled: { type: :boolean }
                   }
                 }
               }
        run_test!
      end

      response '401', 'invalid credentials or MFA required' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
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
        let(:code) { 'test-sso-code' }
        let(:body) { { code: code } }

        before do
          Rails.cache = ActiveSupport::Cache::MemoryStore.new

          Rails.cache.write(
            "mobile_sso:#{code}",
            {
              access_token: 'access-token',
              refresh_token: 'refresh-token',
              token_type: 'Bearer',
              expires_in: 2_592_000,
              created_at: Time.current.to_i,
              user_id: SecureRandom.uuid,
              user_email: 'sso.user@example.com',
              user_first_name: 'SSO',
              user_last_name: 'User',
              user_ui_layout: 'dashboard',
              user_ai_enabled: false
            }
          )
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
                     first_name: { type: :string },
                     last_name: { type: :string },
                     ui_layout: { type: :string, enum: %w[dashboard intro] },
                     ai_enabled: { type: :boolean }
                   }
                 }
               }
        run_test!
      end

      response '401', 'invalid or expired code' do
        let(:body) { { code: 'invalid' } }
        schema '$ref' => '#/components/schemas/ErrorResponse'
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

      response '200', 'token refreshed' do
        schema type: :object,
               properties: {
                 access_token: { type: :string },
                 refresh_token: { type: :string },
                 token_type: { type: :string },
                 expires_in: { type: :integer },
                 created_at: { type: :integer }
               }
        run_test!
      end

      response '401', 'invalid refresh token' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end

      response '400', 'missing refresh token' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end
    end
  end

  path '/api/v1/auth/enable_ai' do
    patch 'Enable AI features for the authenticated user' do
      tags 'Auth'
      consumes 'application/json'
      produces 'application/json'
      security [ { apiKeyAuth: [] } ]

      response '200', 'ai enabled' do
        schema type: :object,
               properties: {
                 user: {
                   type: :object,
                   properties: {
                     id: { type: :string, format: :uuid },
                     email: { type: :string },
                     first_name: { type: :string, nullable: true },
                     last_name: { type: :string, nullable: true },
                     ui_layout: { type: :string, enum: %w[dashboard intro] },
                     ai_enabled: { type: :boolean }
                   }
                 }
               }
        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end

      response '403', 'insufficient scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end
    end
  end
end

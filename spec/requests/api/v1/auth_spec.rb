# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Auth', type: :request do
  let(:password) { 'Docs-Pass1!' }
  let(:device) do
    {
      device_id: 'rswag-docs-device',
      device_name: 'Docs iPhone',
      device_type: 'ios',
      os_version: '17.0',
      app_version: '1.0.0'
    }
  end
  let(:family) { Family.create!(name: 'Auth Docs Family', currency: 'USD', locale: 'en', date_format: '%m-%d-%Y') }
  let(:user) do
    family.users.create!(
      email: 'auth-docs-user@example.com',
      password: password,
      password_confirmation: password,
      first_name: 'Auth',
      last_name: 'Docs',
      role: 'admin'
    )
  end
  let(:linking_code) { 'rswag-linking-code' }

  # Linking and exchange codes live in Rails.cache, which is a null store in tests.
  around do |example|
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_cache
  end

  # The memoized mobile OAuth application would point at a row rolled back by an earlier example.
  before { MobileDevice.instance_variable_set(:@shared_oauth_application, nil) }

  def write_linking_code(**attributes)
    Rails.cache.write("mobile_sso_link:#{linking_code}", {
      provider: 'google_oauth2',
      uid: 'rswag-google-uid',
      email: 'sso-docs-user@example.com',
      first_name: 'Sso',
      last_name: 'Docs',
      name: 'Sso Docs',
      device_info: device.stringify_keys,
      allow_account_creation: true
    }.merge(attributes))
  end

  def api_key_with_scope(scope)
    key = ApiKey.generate_secure_key
    ApiKey.create!(user: user, name: "API Docs Key (#{scope})", key: key, scopes: [ scope ], source: 'web')
  end

  path '/api/v1/auth/signup' do
    post 'Sign up a new user' do
      tags 'Auth'
      consumes 'application/json'
      produces 'application/json'
      description 'Creates a new user and family. The first user on a fresh instance is assigned ' \
                  'the super_admin role; later family creators are assigned an admin role.'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          user: {
            type: :object,
            properties: {
              email: { type: :string, format: :email, description: 'User email address' },
              password: { type: :string, description: 'Password (min 8 chars, max 72 bytes, mixed case, number, special char)' },
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

        let(:body) { { user: { email: 'new-docs-user@example.com', password: password, first_name: 'Docs', last_name: 'User' }, device: device } }

        run_test!
      end

      response '422', 'validation error' do
        schema oneOf: [
          {
            type: :object,
            required: %w[errors],
            properties: { errors: { type: :array, items: { type: :string } } }
          },
          { '$ref' => '#/components/schemas/ErrorResponse' }
        ]

        let(:body) { { user: { email: 'new-docs-user@example.com', password: 'short' }, device: device } }

        run_test!
      end

      response '403', 'registration refused: the instance is closed to new registrations, or an invite code is required or invalid' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { user: { email: 'new-docs-user@example.com', password: password }, device: device } }

        before { allow(Setting).to receive(:onboarding_state).and_return('closed') }

        run_test!
      end

      response '400', 'bad request: the user payload is missing, or device information is missing or invalid' do
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

        let(:body) { { email: user.email, password: password, device: device } }

        run_test!
      end

      response '401', 'invalid credentials, MFA required, or account deactivated' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end

      response '403', 'local login is disabled: the instance is SSO-only, and this account is not a super admin using the emergency override' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { email: user.email, password: password, device: device } }

        before do
          allow(AuthConfig).to receive(:local_login_enabled?).and_return(false)
          allow(AuthConfig).to receive(:local_admin_override_enabled?).and_return(false)
        end

        run_test!
      end
    end
  end

  path '/api/v1/auth/sso_providers' do
    get 'List configured SSO providers' do
      tags 'Auth'
      produces 'application/json'
      description 'Lists the SSO providers configured on this instance. Each name can be used with GET /auth/mobile/{name} to start mobile SSO.'

      response '200', 'providers listed' do
        schema type: :object,
               properties: {
                 providers: {
                   type: :array,
                   items: {
                     type: :object,
                     properties: {
                       name: { type: :string, description: 'Provider name used in /auth/mobile/{name}' },
                       strategy: { type: :string, description: 'OmniAuth strategy, e.g. openid_connect, google_oauth2, github, saml' },
                       label: { type: :string, description: 'Button label' }
                     },
                     required: %w[name strategy label]
                   }
                 }
               },
               required: %w[providers]
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
                     first_name: { type: :string },
                     last_name: { type: :string },
                     ui_layout: { type: :string, enum: %w[dashboard intro] },
                     ai_enabled: { type: :boolean }
                   }
                 }
               }

        let(:body) { { code: 'rswag-sso-code' } }

        before do
          Rails.cache.write('mobile_sso:rswag-sso-code', {
            access_token: 'rswag-access-token',
            refresh_token: 'rswag-refresh-token',
            token_type: 'Bearer',
            expires_in: 30.days.to_i,
            created_at: Time.current.to_i,
            user_id: user.id,
            user_email: user.email,
            user_first_name: user.first_name,
            user_last_name: user.last_name,
            user_ui_layout: user.ui_layout,
            user_ai_enabled: user.ai_enabled?
          })
        end

        run_test!
      end

      response '401', 'invalid or expired code' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { code: 'rswag-expired-code' } }

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

        let(:body) do
          tokens = MobileDevice.upsert_device!(user, device).issue_token!
          { refresh_token: tokens[:refresh_token], device: { device_id: device[:device_id] } }
        end

        run_test!
      end

      response '401', 'invalid or revoked refresh token, or account deactivated' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { refresh_token: 'rswag-revoked-token', device: { device_id: device[:device_id] } } }

        run_test!
      end

      response '400', 'missing refresh token' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end
    end
  end

  path '/api/v1/auth/sso_link' do
    post 'Link an existing account via SSO' do
      tags 'Auth'
      consumes 'application/json'
      produces 'application/json'
      description 'Authenticates with email/password and links the SSO identity from a previously issued linking code. Creates an OidcIdentity, logs the link via SsoAuditLog, and issues mobile OAuth tokens.'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          linking_code: { type: :string, description: 'One-time linking code from mobile SSO onboarding redirect' },
          email: { type: :string, format: :email, description: 'Email of the existing account to link' },
          password: { type: :string, description: 'Password for the existing account' }
        },
        required: %w[linking_code email password]
      }

      response '200', 'account linked and tokens issued' do
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

        let(:body) { { linking_code: linking_code, email: user.email, password: password } }

        before { write_linking_code }

        run_test!
      end

      response '400', 'missing linking code' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end

      response '401', 'invalid credentials, expired linking code, or account deactivated' do
        schema oneOf: [
          { '$ref' => '#/components/schemas/ErrorResponse' },
          { '$ref' => '#/components/schemas/MfaRequiredResponse' }
        ]

        let(:body) { { linking_code: 'rswag-expired-link', email: user.email, password: password } }

        run_test!
      end

      response '403', 'SSO identity removed by an administrator' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:linking_code) { 'rswag-removed-identity' }
        let(:removed_uid) { 'rswag-removed-subject' }
        let(:body) do
          {
            linking_code: linking_code,
            email: 'removed@example.com',
            password: 'unused-password'
          }
        end

        before do
          Rails.cache.write("mobile_sso_link:#{linking_code}", {
            provider: 'openid_connect',
            uid: removed_uid
          })
          SsoIdentityBlock.create!(
            provider: 'openid_connect',
            uid_digest: SsoIdentityBlock.digest(removed_uid),
            identity_label: 'removed@example.com'
          )
        end

        run_test!
      end
    end
  end

  path '/api/v1/auth/sso_create_account' do
    post 'Create a new account via SSO' do
      tags 'Auth'
      consumes 'application/json'
      produces 'application/json'
      description 'Creates a new user and family from a previously issued linking code. Links the SSO identity ' \
                  'via OidcIdentity, logs the JIT account creation via SsoAuditLog, and issues mobile OAuth tokens. ' \
                  'The linking code must have allow_account_creation enabled. The first user on a fresh instance is ' \
                  'assigned the super_admin role; later family creators are assigned an admin-capable role.'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          linking_code: { type: :string, description: 'One-time linking code from mobile SSO onboarding redirect' },
          first_name: { type: :string, description: 'First name (overrides value from SSO provider if provided)' },
          last_name: { type: :string, description: 'Last name (overrides value from SSO provider if provided)' }
        },
        required: %w[linking_code]
      }

      response '200', 'account created and tokens issued' do
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

        let(:body) { { linking_code: linking_code, first_name: 'Sso', last_name: 'Docs' } }

        before { write_linking_code }

        run_test!
      end

      response '400', 'missing linking code' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end

      response '401', 'invalid or expired linking code' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { linking_code: 'rswag-expired-link' } }

        run_test!
      end

      response '403', 'SSO identity removed or account creation disabled' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { linking_code: linking_code } }

        before { write_linking_code(allow_account_creation: false) }

        run_test!
      end

      response '422', 'user validation error' do
        schema type: :object,
               properties: {
                 errors: {
                   type: :array,
                   items: { type: :string }
                 }
               }

        let(:body) { { linking_code: linking_code } }

        before { write_linking_code(email: user.email) }

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

        let(:'X-Api-Key') { api_key_with_scope('read_write').plain_key }

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'insufficient scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_with_scope('read').plain_key }

        run_test!
      end
    end
  end
end

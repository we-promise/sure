require "test_helper"

class Api::V1::AuthControllerTest < ActionDispatch::IntegrationTest
  setup do
    # Clean up any existing invite codes
    InviteCode.destroy_all
    @device_info = {
      device_id: "test-device-123",
      device_name: "Test iPhone",
      device_type: "ios",
      os_version: "17.0",
      app_version: "1.0.0"
    }

    # Ensure the shared OAuth application exists
    @shared_app = Doorkeeper::Application.find_or_create_by!(name: "Sure Mobile") do |app|
      app.redirect_uri = "sureapp://oauth/callback"
      app.scopes = "read read_write"
      app.confidential = false
    end
    @shared_app.update!(scopes: "read read_write")

    # Clear the memoized class variable so it picks up the test record
    MobileDevice.instance_variable_set(:@shared_oauth_application, nil)

    # Use a real cache store for SSO linking tests (test env uses :null_store by default)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache if @original_cache
  end

  test "should signup new user and return OAuth tokens" do
    assert_difference("User.count", 1) do
      assert_difference("MobileDevice.count", 1) do
        assert_no_difference("Doorkeeper::Application.count") do
          assert_difference("Doorkeeper::AccessToken.count", 1) do
            post "/api/v1/auth/signup", params: {
              user: {
                email: "newuser@example.com",
                password: "SecurePass123!",
                first_name: "New",
                last_name: "User"
              },
              device: @device_info
            }
          end
        end
      end
    end

    assert_response :created
    response_data = JSON.parse(response.body)

    assert response_data["user"]["id"].present?
    assert_equal "newuser@example.com", response_data["user"]["email"]
    assert_equal "New", response_data["user"]["first_name"]
    assert_equal "User", response_data["user"]["last_name"]
    new_user = User.find(response_data["user"]["id"])
    assert_equal new_user.ui_layout, response_data["user"]["ui_layout"]
    assert_equal new_user.ai_enabled?, response_data["user"]["ai_enabled"]

    # OAuth token assertions
    assert response_data["access_token"].present?
    assert response_data["refresh_token"].present?
    assert_equal "Bearer", response_data["token_type"]
    assert_equal 2592000, response_data["expires_in"] # 30 days
    assert response_data["created_at"].present?

    # Verify the device was created
    created_user = User.find(response_data["user"]["id"])
    device = created_user.mobile_devices.first
    assert_equal @device_info[:device_id], device.device_id
    assert_equal @device_info[:device_name], device.device_name
    assert_equal @device_info[:device_type], device.device_type
  end

  test "should not signup without device info" do
    assert_no_difference("User.count") do
      post "/api/v1/auth/signup", params: {
        user: {
          email: "newuser@example.com",
          password: "SecurePass123!",
          first_name: "New",
          last_name: "User"
        }
      }
    end

    assert_response :bad_request
    response_data = JSON.parse(response.body)
    assert_equal "Device information is required", response_data["error"]
  end

  test "should reject signup with invalid device_type before committing any state" do
    # Pre-validation catches bad device_type and returns 400 without creating
    # user/family/device/token. Guards against a partial-commit state where the
    # account exists but the mobile session handoff fails.
    assert_no_difference([ "User.count", "MobileDevice.count", "Doorkeeper::AccessToken.count" ]) do
      post "/api/v1/auth/signup", params: {
        user: {
          email: "newuser@example.com",
          password: "SecurePass123!",
          first_name: "New",
          last_name: "User"
        },
        device: @device_info.merge(device_type: "windows") # not in allowlist
      }
    end

    assert_response :bad_request
  end

  test "should not signup with invalid password" do
    assert_no_difference("User.count") do
      post "/api/v1/auth/signup", params: {
        user: {
          email: "newuser@example.com",
          password: "weak",
          first_name: "New",
          last_name: "User"
        },
        device: @device_info
      }
    end

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert response_data["errors"].include?("Password must be at least 8 characters")
  end

  test "should not signup with duplicate email" do
    existing_user = users(:family_admin)

    assert_no_difference("User.count") do
      post "/api/v1/auth/signup", params: {
        user: {
          email: existing_user.email,
          password: "SecurePass123!",
          first_name: "Duplicate",
          last_name: "User"
        },
        device: @device_info
      }
    end

    assert_response :unprocessable_entity
  end

  test "should create user with admin role and family" do
    post "/api/v1/auth/signup", params: {
      user: {
        email: "newuser@example.com",
        password: "SecurePass123!",
        first_name: "New",
        last_name: "User"
      },
      device: @device_info
    }

    assert_response :created
    response_data = JSON.parse(response.body)

    new_user = User.find(response_data["user"]["id"])
    assert_equal "admin", new_user.role
    assert new_user.family.present?
  end

  test "should require invite code when enabled" do
    # Mock invite code requirement
    Api::V1::AuthController.any_instance.stubs(:invite_code_required?).returns(true)

    assert_no_difference("User.count") do
      post "/api/v1/auth/signup", params: {
        user: {
          email: "newuser@example.com",
          password: "SecurePass123!",
          first_name: "New",
          last_name: "User"
        },
        device: @device_info
      }
    end

    assert_response :forbidden
    response_data = JSON.parse(response.body)
    assert_equal "Invite code is required", response_data["error"]
  end

  test "should signup with valid invite code when required" do
    # Create a valid invite code
    invite_code = InviteCode.create!

    # Mock invite code requirement
    Api::V1::AuthController.any_instance.stubs(:invite_code_required?).returns(true)

    assert_difference("User.count", 1) do
      assert_difference("InviteCode.count", -1) do
        post "/api/v1/auth/signup", params: {
          user: {
            email: "newuser@example.com",
            password: "SecurePass123!",
            first_name: "New",
            last_name: "User"
          },
          device: @device_info,
          invite_code: invite_code.token
        }
      end
    end

    assert_response :created
  end

  test "should reject invalid invite code" do
    # Mock invite code requirement
    Api::V1::AuthController.any_instance.stubs(:invite_code_required?).returns(false)

    assert_no_difference("User.count") do
      post "/api/v1/auth/signup", params: {
        user: {
          email: "newuser@example.com",
          password: "SecurePass123!",
          first_name: "New",
          last_name: "User"
        },
        device: @device_info,
        invite_code: "invalid_code"
      }
    end

    assert_response :forbidden
    response_data = JSON.parse(response.body)
    assert_equal "Invalid invite code", response_data["error"]
  end

  test "should login existing user and return OAuth tokens" do
    user = users(:family_admin)
    password = user_password_test

    # Ensure user has no mobile devices
    user.mobile_devices.destroy_all

    assert_difference("MobileDevice.count", 1) do
      assert_difference("Doorkeeper::AccessToken.count", 1) do
        post "/api/v1/auth/login", params: {
          email: user.email,
          password: password,
          device: @device_info
        }
      end
    end

    assert_response :success
    response_data = JSON.parse(response.body)

    assert_equal user.id.to_s, response_data["user"]["id"]
    assert_equal user.email, response_data["user"]["email"]
    assert_equal user.ui_layout, response_data["user"]["ui_layout"]
    assert_equal user.ai_enabled?, response_data["user"]["ai_enabled"]

    # OAuth token assertions
    assert response_data["access_token"].present?
    assert response_data["refresh_token"].present?
    assert_equal "Bearer", response_data["token_type"]
    assert_equal 2592000, response_data["expires_in"] # 30 days

    # Verify the device
    device = user.mobile_devices.where(device_id: @device_info[:device_id]).first
    assert device.present?
    assert device.active?
  end

  test "should require MFA when enabled" do
    user = users(:family_admin)
    password = user_password_test

    # Enable MFA for user
    user.setup_mfa!
    user.enable_mfa!

    post "/api/v1/auth/login", params: {
      email: user.email,
      password: password,
      device: @device_info
    }

    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    assert_equal "Two-factor authentication required", response_data["error"]
    assert response_data["mfa_required"]
  end

  test "should login with valid MFA code" do
    user = users(:family_admin)
    password = user_password_test

    # Enable MFA for user
    user.setup_mfa!
    user.enable_mfa!
    totp = ROTP::TOTP.new(user.otp_secret)

    assert_difference("Doorkeeper::AccessToken.count", 1) do
      post "/api/v1/auth/login", params: {
        email: user.email,
        password: password,
        otp_code: totp.now,
        device: @device_info
      }
    end

    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data["access_token"].present?
  end

  test "should revoke existing tokens for same device on login" do
    user = users(:family_admin)
    password = user_password_test

    # Create an existing device and token
    device = user.mobile_devices.create!(@device_info)
    existing_token = Doorkeeper::AccessToken.create!(
      application: @shared_app,
      resource_owner_id: user.id,
      mobile_device_id: device.id,
      expires_in: 30.days.to_i,
      scopes: "read_write"
    )

    assert existing_token.accessible?

    post "/api/v1/auth/login", params: {
      email: user.email,
      password: password,
      device: @device_info
    }

    assert_response :success

    # Check that old token was revoked
    existing_token.reload
    assert existing_token.revoked?
  end

  test "should not login with invalid password" do
    user = users(:family_admin)

    assert_no_difference("Doorkeeper::AccessToken.count") do
      post "/api/v1/auth/login", params: {
        email: user.email,
        password: "wrong_password",
        device: @device_info
      }
    end

    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    assert_equal "Invalid email or password", response_data["error"]
  end

  test "should not login with non-existent email" do
    assert_no_difference("Doorkeeper::AccessToken.count") do
      post "/api/v1/auth/login", params: {
        email: "nonexistent@example.com",
        password: user_password_test,
        device: @device_info
      }
    end

    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    assert_equal "Invalid email or password", response_data["error"]
  end

  test "should login even when OAuth application is missing" do
    user = users(:family_admin)
    password = user_password_test

    # Simulate a fresh instance where seeds were never run
    Doorkeeper::Application.where(name: "Sure Mobile").destroy_all
    MobileDevice.instance_variable_set(:@shared_oauth_application, nil)

    assert_difference("Doorkeeper::Application.count", 1) do
      post "/api/v1/auth/login", params: {
        email: user.email,
        password: password,
        device: @device_info
      }
    end

    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data["access_token"].present?
    assert response_data["refresh_token"].present?
  end

  test "should not login without device info" do
    user = users(:family_admin)

    assert_no_difference("Doorkeeper::AccessToken.count") do
      post "/api/v1/auth/login", params: {
        email: user.email,
        password: user_password_test
      }
    end

    assert_response :bad_request
    response_data = JSON.parse(response.body)
    assert_equal "Device information is required", response_data["error"]
  end

  test "should refresh access token with valid refresh token" do
    user = users(:family_admin)
    device = user.mobile_devices.create!(@device_info)

    # Create initial token
    initial_token = Doorkeeper::AccessToken.create!(
      application: @shared_app,
      resource_owner_id: user.id,
      mobile_device_id: device.id,
      expires_in: 30.days.to_i,
      scopes: "read_write",
      use_refresh_token: true
    )

    # Wait to ensure different timestamps
    sleep 0.1

    assert_difference("Doorkeeper::AccessToken.count", 1) do
      post "/api/v1/auth/refresh", params: {
        refresh_token: initial_token.refresh_token,
        device: @device_info
      }
    end

    assert_response :success
    response_data = JSON.parse(response.body)

    # New token assertions
    assert response_data["access_token"].present?
    assert response_data["refresh_token"].present?
    assert_not_equal initial_token.token, response_data["access_token"]
    assert_equal 2592000, response_data["expires_in"]

    # Old token should be revoked
    initial_token.reload
    assert initial_token.revoked?
  end

  test "should not refresh with invalid refresh token" do
    assert_no_difference("Doorkeeper::AccessToken.count") do
      post "/api/v1/auth/refresh", params: {
        refresh_token: "invalid_token",
        device: @device_info
      }
    end

    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    assert_equal "Invalid refresh token", response_data["error"]
  end

  test "should not refresh without refresh token" do
    post "/api/v1/auth/refresh", params: {
      device: @device_info
    }

    assert_response :bad_request
    response_data = JSON.parse(response.body)
    assert_equal "Refresh token is required", response_data["error"]
  end

  test "should enable ai for authenticated user" do
    user = users(:family_admin)
    user.update!(ai_enabled: false)
    device = user.mobile_devices.create!(@device_info)
    token = Doorkeeper::AccessToken.create!(application: @shared_app, resource_owner_id: user.id, mobile_device_id: device.id, scopes: "read_write")

    patch "/api/v1/auth/enable_ai", headers: {
      "Authorization" => "Bearer #{token.token}",
      "Content-Type" => "application/json"
    }

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal true, response_data.dig("user", "ai_enabled")
    assert_equal user.ui_layout, response_data.dig("user", "ui_layout")
    assert_equal true, user.reload.ai_enabled
  end

  test "should require read_write scope to enable ai" do
    user = users(:family_admin)
    user.update!(ai_enabled: false)
    device = user.mobile_devices.create!(@device_info)
    token = Doorkeeper::AccessToken.create!(application: @shared_app, resource_owner_id: user.id, mobile_device_id: device.id, scopes: "read")

    patch "/api/v1/auth/enable_ai", headers: {
      "Authorization" => "Bearer #{token.token}",
      "Content-Type" => "application/json"
    }

    assert_response :forbidden
    response_data = JSON.parse(response.body)
    assert_equal "insufficient_scope", response_data["error"]
    assert_equal "This action requires the 'write' scope", response_data["message"]
    assert_not user.reload.ai_enabled
  end

  test "should require authentication when enabling ai" do
    patch "/api/v1/auth/enable_ai", headers: { "Content-Type" => "application/json" }

    assert_response :unauthorized
  end

  # SSO Link tests
  test "should link existing account via SSO and return tokens" do
    user = users(:family_admin)

    linking_code = SecureRandom.urlsafe_base64(32)
    Rails.cache.write("mobile_sso_link:#{linking_code}", {
      provider: "google_oauth2",
      uid: "google-uid-123",
      email: "google@example.com",
      first_name: "Google",
      last_name: "User",
      name: "Google User",
      device_info: @device_info.stringify_keys,
      allow_account_creation: true
    }, expires_in: 10.minutes)

    assert_difference("OidcIdentity.count", 1) do
      post "/api/v1/auth/sso_link", params: {
        linking_code: linking_code,
        email: user.email,
        password: user_password_test
      }
    end

    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data["access_token"].present?
    assert response_data["refresh_token"].present?
    assert_equal user.id.to_s, response_data["user"]["id"]

    # Linking code should be consumed
    assert_nil Rails.cache.read("mobile_sso_link:#{linking_code}")
  end

  test "should reject SSO link with invalid password" do
    user = users(:family_admin)

    linking_code = SecureRandom.urlsafe_base64(32)
    Rails.cache.write("mobile_sso_link:#{linking_code}", {
      provider: "google_oauth2",
      uid: "google-uid-123",
      email: "google@example.com",
      device_info: @device_info.stringify_keys,
      allow_account_creation: true
    }, expires_in: 10.minutes)

    assert_no_difference("OidcIdentity.count") do
      post "/api/v1/auth/sso_link", params: {
        linking_code: linking_code,
        email: user.email,
        password: "wrong_password"
      }
    end

    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    assert_equal "Invalid email or password", response_data["error"]

    # Linking code should NOT be consumed on failed password
    assert Rails.cache.read("mobile_sso_link:#{linking_code}").present?, "Expected linking code to survive a failed attempt"
  end

  test "should reject SSO link when user has MFA enabled" do
    user = users(:family_admin)
    user.update!(otp_required: true, otp_secret: ROTP::Base32.random(32))

    linking_code = SecureRandom.urlsafe_base64(32)
    Rails.cache.write("mobile_sso_link:#{linking_code}", {
      provider: "google_oauth2",
      uid: "google-uid-mfa",
      email: "mfa@example.com",
      first_name: "MFA",
      last_name: "User",
      name: "MFA User",
      device_info: @device_info.stringify_keys,
      allow_account_creation: true
    }, expires_in: 10.minutes)

    assert_no_difference("OidcIdentity.count") do
      post "/api/v1/auth/sso_link", params: {
        linking_code: linking_code,
        email: user.email,
        password: user_password_test
      }
    end

    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    assert_equal true, response_data["mfa_required"]
    assert_match(/MFA/, response_data["error"])

    # Linking code should NOT be consumed on MFA rejection
    assert Rails.cache.read("mobile_sso_link:#{linking_code}").present?, "Expected linking code to survive MFA rejection"
  end

  test "should reject SSO link with expired linking code" do
    post "/api/v1/auth/sso_link", params: {
      linking_code: "expired-code",
      email: "test@example.com",
      password: "password"
    }

    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    assert_equal "Linking code is invalid or expired", response_data["error"]
  end

  test "should reject SSO link without linking code" do
    post "/api/v1/auth/sso_link", params: {
      email: "test@example.com",
      password: "password"
    }

    assert_response :bad_request
    response_data = JSON.parse(response.body)
    assert_equal "Linking code is required", response_data["error"]
  end

  test "linking_code is single-use under race" do
    user = users(:family_admin)

    linking_code = SecureRandom.urlsafe_base64(32)
    Rails.cache.write("mobile_sso_link:#{linking_code}", {
      provider: "google_oauth2",
      uid: "google-uid-race-test",
      email: "race@example.com",
      first_name: "Race",
      last_name: "Test",
      name: "Race Test",
      device_info: @device_info.stringify_keys,
      allow_account_creation: true
    }, expires_in: 10.minutes)

    # First request succeeds
    assert_difference("OidcIdentity.count", 1) do
      post "/api/v1/auth/sso_link", params: {
        linking_code: linking_code,
        email: user.email,
        password: user_password_test
      }
    end
    assert_response :success

    # Second request with the same code is rejected
    assert_no_difference("OidcIdentity.count") do
      post "/api/v1/auth/sso_link", params: {
        linking_code: linking_code,
        email: user.email,
        password: user_password_test
      }
    end
    assert_response :unauthorized
    assert_equal "Linking code is invalid or expired", JSON.parse(response.body)["error"]
    assert_nil Rails.cache.read("mobile_sso_link:#{linking_code}")
  end

  # SSO Create Account tests
  test "should create new account via SSO and return tokens" do
    linking_code = SecureRandom.urlsafe_base64(32)
    Rails.cache.write("mobile_sso_link:#{linking_code}", {
      provider: "google_oauth2",
      uid: "google-uid-456",
      email: "newgoogleuser@example.com",
      first_name: "New",
      last_name: "GoogleUser",
      name: "New GoogleUser",
      device_info: @device_info.stringify_keys,
      allow_account_creation: true
    }, expires_in: 10.minutes)

    assert_difference([ "User.count", "OidcIdentity.count" ], 1) do
      post "/api/v1/auth/sso_create_account", params: {
        linking_code: linking_code,
        first_name: "New",
        last_name: "GoogleUser"
      }
    end

    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data["access_token"].present?
    assert response_data["refresh_token"].present?
    assert_equal "newgoogleuser@example.com", response_data["user"]["email"]
    assert_equal "New", response_data["user"]["first_name"]
    assert_equal "GoogleUser", response_data["user"]["last_name"]

    # Linking code should be consumed
    assert_nil Rails.cache.read("mobile_sso_link:#{linking_code}")
  end

  test "should reject SSO create account when not allowed" do
    linking_code = SecureRandom.urlsafe_base64(32)
    Rails.cache.write("mobile_sso_link:#{linking_code}", {
      provider: "google_oauth2",
      uid: "google-uid-789",
      email: "blocked@example.com",
      first_name: "Blocked",
      last_name: "User",
      device_info: @device_info.stringify_keys,
      allow_account_creation: false
    }, expires_in: 10.minutes)

    assert_no_difference("User.count") do
      post "/api/v1/auth/sso_create_account", params: {
        linking_code: linking_code,
        first_name: "Blocked",
        last_name: "User"
      }
    end

    assert_response :forbidden
    response_data = JSON.parse(response.body)
    assert_match(/disabled/, response_data["error"])

    # Linking code should NOT be consumed on rejection
    assert Rails.cache.read("mobile_sso_link:#{linking_code}").present?, "Expected linking code to survive a rejected create account attempt"
  end

  test "should reject SSO create account with expired linking code" do
    post "/api/v1/auth/sso_create_account", params: {
      linking_code: "expired-code",
      first_name: "Test",
      last_name: "User"
    }

    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    assert_equal "Linking code is invalid or expired", response_data["error"]
  end

  test "should reject SSO create account without linking code" do
    post "/api/v1/auth/sso_create_account", params: {
      first_name: "Test",
      last_name: "User"
    }

    assert_response :bad_request
    response_data = JSON.parse(response.body)
    assert_equal "Linking code is required", response_data["error"]
  end

  test "should return 422 when SSO create account fails user validation" do
    existing_user = users(:family_admin)

    linking_code = SecureRandom.urlsafe_base64(32)
    Rails.cache.write("mobile_sso_link:#{linking_code}", {
      provider: "google_oauth2",
      uid: "google-uid-dup-email",
      email: existing_user.email,
      first_name: "Duplicate",
      last_name: "Email",
      name: "Duplicate Email",
      device_info: @device_info.stringify_keys,
      allow_account_creation: true
    }, expires_in: 10.minutes)

    assert_no_difference([ "User.count", "OidcIdentity.count" ]) do
      post "/api/v1/auth/sso_create_account", params: {
        linking_code: linking_code,
        first_name: "Duplicate",
        last_name: "Email"
      }
    end

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert response_data["errors"].any? { |e| e.match?(/email/i) }, "Expected email validation error in: #{response_data["errors"]}"
  end

  test "sso_create_account linking_code single-use under race" do
    linking_code = SecureRandom.urlsafe_base64(32)
    Rails.cache.write("mobile_sso_link:#{linking_code}", {
      provider: "google_oauth2",
      uid: "google-uid-race-create",
      email: "raceuser@example.com",
      first_name: "Race",
      last_name: "CreateUser",
      name: "Race CreateUser",
      device_info: @device_info.stringify_keys,
      allow_account_creation: true
    }, expires_in: 10.minutes)

    # First request succeeds
    assert_difference([ "User.count", "OidcIdentity.count" ], 1) do
      post "/api/v1/auth/sso_create_account", params: {
        linking_code: linking_code,
        first_name: "Race",
        last_name: "CreateUser"
      }
    end
    assert_response :success

    # Second request with the same code is rejected
    assert_no_difference([ "User.count", "OidcIdentity.count" ]) do
      post "/api/v1/auth/sso_create_account", params: {
        linking_code: linking_code,
        first_name: "Race",
        last_name: "CreateUser"
      }
    end
    assert_response :unauthorized
    assert_equal "Linking code is invalid or expired", JSON.parse(response.body)["error"]
    assert_nil Rails.cache.read("mobile_sso_link:#{linking_code}")
  end

  test "should return forbidden when ai is not available" do
    user = users(:family_admin)
    user.update!(ai_enabled: false)
    device = user.mobile_devices.create!(@device_info)
    token = Doorkeeper::AccessToken.create!(application: @shared_app, resource_owner_id: user.id, mobile_device_id: device.id, scopes: "read_write")
    User.any_instance.stubs(:ai_available?).returns(false)

    patch "/api/v1/auth/enable_ai", headers: {
      "Authorization" => "Bearer #{token.token}",
      "Content-Type" => "application/json"
    }

    assert_response :forbidden
    response_data = JSON.parse(response.body)
    assert_equal "AI is not available for your account", response_data["error"]
    assert_not user.reload.ai_enabled
  end

  # Security tests — ported from origin/security/pentest-2026-03-02

  test "signup is blocked when registration is closed on self-hosted" do
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(true)
    Setting.stubs(:onboarding_state).returns("closed")

    post "/api/v1/auth/signup", params: {
      user: { email: "new@example.com", password: "SecurePass123!", first_name: "New", last_name: "User" },
      device: @device_info
    }

    assert_response :forbidden
    assert_equal "Registration is currently closed", JSON.parse(response.body)["error"]
  end

  test "login is blocked when local login disabled via AuthConfig" do
    AuthConfig.stubs(:local_login_enabled?).returns(false)

    post "/api/v1/auth/login", params: {
      email: users(:family_admin).email,
      password: user_password_test,
      device: @device_info
    }

    assert_response :forbidden
    assert_equal "Local login is disabled. Please use SSO.", JSON.parse(response.body)["error"]
  end

  test "refresh token is rejected for deactivated user and new token is revoked" do
    user = users(:family_member)
    device = user.mobile_devices.create!(@device_info)

    initial_token = Doorkeeper::AccessToken.create!(
      application: @shared_app,
      resource_owner_id: user.id,
      mobile_device_id: device.id,
      expires_in: 30.days.to_i,
      scopes: "read_write",
      use_refresh_token: true
    )

    user.update!(active: false)

    post "/api/v1/auth/refresh", params: {
      refresh_token: initial_token.refresh_token,
      device: @device_info
    }

    assert_response :unauthorized
    assert_equal "Account has been deactivated", JSON.parse(response.body)["error"]

    # All tokens for this user must be revoked (including any newly issued one)
    assert Doorkeeper::AccessToken.where(resource_owner_id: user.id).all?(&:revoked?),
      "Expected all tokens to be revoked for deactivated user"
  end

  test "login is rejected for deactivated user" do
    user = users(:family_member)
    user.update!(active: false)

    post "/api/v1/auth/login", params: {
      email: user.email,
      password: user_password_test,
      device: @device_info
    }

    assert_response :unauthorized
    assert_equal "Account has been deactivated", JSON.parse(response.body)["error"]
  end
end

module Api
  module V1
    class AuthController < BaseController
      include Invitable

      skip_before_action :authenticate_request!
      skip_before_action :check_api_key_rate_limit
      skip_before_action :log_api_access
      before_action :authenticate_request!, only: :enable_ai
      before_action :ensure_write_scope, only: :enable_ai
      before_action :check_api_key_rate_limit, only: :enable_ai
      before_action :log_api_access, only: :enable_ai

      def signup
        # Check if invite code is required
        if invite_code_required? && params[:invite_code].blank?
          render json: { error: "Invite code is required" }, status: :forbidden
          return
        end

        # Validate invite code if provided
        if params[:invite_code].present? && !InviteCode.exists?(token: params[:invite_code]&.downcase)
          render json: { error: "Invalid invite code" }, status: :forbidden
          return
        end

        # Validate password
        password_errors = validate_password(params[:user][:password])
        if password_errors.any?
          render json: { errors: password_errors }, status: :unprocessable_entity
          return
        end

        # Validate device info
        unless valid_device_info?
          render json: { error: "Device information is required" }, status: :bad_request
          return
        end

        user = User.new(user_signup_params)

        # Create family for new user
        # First user of an instance becomes super_admin
        family = Family.new
        user.family = family
        user.role = User.role_for_new_family_creator

        if user.save
          # Claim invite code if provided
          InviteCode.claim!(params[:invite_code]) if params[:invite_code].present?

          # Create device and OAuth token
          begin
            device = MobileDevice.upsert_device!(user, device_params)
            token_response = device.issue_token!
          rescue ActiveRecord::RecordInvalid => e
            render json: { error: "Failed to register device: #{e.message}" }, status: :unprocessable_entity
            return
          end

          render json: token_response.merge(user: mobile_user_payload(user)), status: :created
        else
          render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def login
        user = User.find_by(email: params[:email])

        if user&.authenticate(params[:password])
          # Check MFA if enabled
          if user.otp_required?
            unless params[:otp_code].present? && user.verify_otp?(params[:otp_code])
              render json: {
                error: "Two-factor authentication required",
                mfa_required: true
              }, status: :unauthorized
              return
            end
          end

          # Validate device info
          unless valid_device_info?
            render json: { error: "Device information is required" }, status: :bad_request
            return
          end

          # Create device and OAuth token
          begin
            device = MobileDevice.upsert_device!(user, device_params)
            token_response = device.issue_token!
          rescue ActiveRecord::RecordInvalid => e
            render json: { error: "Failed to register device: #{e.message}" }, status: :unprocessable_entity
            return
          end

          render json: token_response.merge(user: mobile_user_payload(user))
        else
          render json: { error: "Invalid email or password" }, status: :unauthorized
        end
      end

      def sso_exchange
        code = sso_exchange_params

        if code.blank?
          render json: { error: "invalid_or_expired_code", message: "Authorization code is required" }, status: :unauthorized
          return
        end

        cache_key = "mobile_sso:#{code}"
        cached = Rails.cache.read(cache_key)

        unless cached.present?
          render json: { error: "invalid_or_expired_code", message: "Authorization code is invalid or expired" }, status: :unauthorized
          return
        end

        # Atomic delete — only the request that successfully deletes the key may proceed.
        # This prevents a race where two concurrent requests both read the same code.
        unless Rails.cache.delete(cache_key)
          render json: { error: "invalid_or_expired_code", message: "Authorization code is invalid or expired" }, status: :unauthorized
          return
        end

        render json: {
          access_token: cached[:access_token],
          refresh_token: cached[:refresh_token],
          token_type: cached[:token_type],
          expires_in: cached[:expires_in],
          created_at: cached[:created_at],
          user: {
            id: cached[:user_id],
            email: cached[:user_email],
            first_name: cached[:user_first_name],
            last_name: cached[:user_last_name],
            ui_layout: cached[:user_ui_layout],
            ai_enabled: cached[:user_ai_enabled]
          }
        }
      end

      def enable_ai
        user = current_resource_owner

        unless user.ai_available?
          render json: { error: "AI is not available for your account" }, status: :forbidden
          return
        end

        if user.update(ai_enabled: true)
          render json: { user: mobile_user_payload(user) }
        else
          render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def refresh
        # Find the refresh token
        refresh_token = params[:refresh_token]

        unless refresh_token.present?
          render json: { error: "Refresh token is required" }, status: :bad_request
          return
        end

        # Find the access token associated with this refresh token
        access_token = Doorkeeper::AccessToken.by_refresh_token(refresh_token)

        if access_token.nil? || access_token.revoked?
          render json: { error: "Invalid refresh token" }, status: :unauthorized
          return
        end

        # Create new access token
        new_token = Doorkeeper::AccessToken.create!(
          application: access_token.application,
          resource_owner_id: access_token.resource_owner_id,
          mobile_device_id: access_token.mobile_device_id,
          expires_in: 30.days.to_i,
          scopes: access_token.scopes,
          use_refresh_token: true
        )

        # Revoke old access token
        access_token.revoke

        # Update device last seen
        user = User.find(access_token.resource_owner_id)
        device = user.mobile_devices.find_by(device_id: params[:device][:device_id])
        device&.update_last_seen!

        render json: {
          access_token: new_token.plaintext_token,
          refresh_token: new_token.plaintext_refresh_token,
          token_type: "Bearer",
          expires_in: new_token.expires_in,
          created_at: new_token.created_at.to_i
        }
      end

      private

        def user_signup_params
          params.require(:user).permit(:email, :password, :first_name, :last_name)
        end

        def validate_password(password)
          errors = []

          if password.blank?
            errors << "Password can't be blank"
            return errors
          end

          errors << "Password must be at least 8 characters" if password.length < 8
          errors << "Password must include both uppercase and lowercase letters" unless password.match?(/[A-Z]/) && password.match?(/[a-z]/)
          errors << "Password must include at least one number" unless password.match?(/\d/)
          errors << "Password must include at least one special character" unless password.match?(/[!@#$%^&*(),.?":{}|<>]/)

          errors
        end

        def valid_device_info?
          device = params[:device]
          return false if device.nil?

          required_fields = %w[device_id device_name device_type os_version app_version]
          required_fields.all? { |field| device[field].present? }
        end

        def device_params
          params.require(:device).permit(:device_id, :device_name, :device_type, :os_version, :app_version)
        end

        def sso_exchange_params
          params.require(:code)
        end

        def mobile_user_payload(user)
          {
            id: user.id,
            email: user.email,
            first_name: user.first_name,
            last_name: user.last_name,
            ui_layout: user.ui_layout,
            ai_enabled: user.ai_enabled?
          }
        end

        def ensure_write_scope
          authorize_scope!(:write)
        end
    end
  end
end

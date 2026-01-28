# frozen_string_literal: true

module Admin
  class SsoProvidersController < Admin::BaseController
    before_action :set_sso_provider, only: %i[show edit update destroy toggle test_connection]

    def index
      authorize SsoProvider
      @sso_providers = policy_scope(SsoProvider).order(:name)

      # Load runtime providers (from YAML/env) that might not be in the database
      # This helps show users that legacy providers are active but not manageable via UI
      @runtime_providers = Rails.configuration.x.auth.sso_providers || []
      db_provider_names = @sso_providers.pluck(:name)
      @legacy_providers = @runtime_providers.reject { |p| db_provider_names.include?(p[:name].to_s) }
      @breadcrumbs = [
        [ t("breadcrumbs.home"), root_path ],
        [ t("breadcrumbs.sso_providers"), nil ]
      ]
    end

    def show
      authorize @sso_provider
    end

    def new
      @sso_provider = SsoProvider.new
      authorize @sso_provider
    end

    def create
      @sso_provider = SsoProvider.new(processed_params)
      authorize @sso_provider

      # Auto-generate redirect_uri if not provided
      if @sso_provider.redirect_uri.blank? && @sso_provider.name.present?
        @sso_provider.redirect_uri = "#{request.base_url}/auth/#{@sso_provider.name}/callback"
      end

      if @sso_provider.save
        log_provider_change(:create, @sso_provider)
        clear_provider_cache
        redirect_to admin_sso_providers_path, notice: t(".success")
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize @sso_provider
    end

    def update
      authorize @sso_provider

      # Auto-update redirect_uri if name changed
      params_hash = processed_params.to_h
      if params_hash[:name].present? && params_hash[:name] != @sso_provider.name
        params_hash[:redirect_uri] = "#{request.base_url}/auth/#{params_hash[:name]}/callback"
      end

      if @sso_provider.update(params_hash)
        log_provider_change(:update, @sso_provider)
        clear_provider_cache
        redirect_to admin_sso_providers_path, notice: t(".success")
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      authorize @sso_provider

      @sso_provider.destroy!
      log_provider_change(:destroy, @sso_provider)
      clear_provider_cache

      redirect_to admin_sso_providers_path, notice: t(".success")
    end

    def toggle
      authorize @sso_provider

      @sso_provider.update!(enabled: !@sso_provider.enabled)
      log_provider_change(:toggle, @sso_provider)
      clear_provider_cache

      notice = @sso_provider.enabled? ? t(".success_enabled") : t(".success_disabled")
      redirect_to admin_sso_providers_path, notice: notice
    end

    def test_connection
      authorize @sso_provider

      tester = SsoProviderTester.new(@sso_provider)
      result = tester.test!

      render json: {
        success: result.success?,
        message: result.message,
        details: result.details
      }
    end

    private
      def set_sso_provider
        @sso_provider = SsoProvider.find(params[:id])
      end

      def sso_provider_params
        params.require(:sso_provider).permit(
          :strategy,
          :name,
          :label,
          :icon,
          :enabled,
          :issuer,
          :client_id,
          :client_secret,
          :redirect_uri,
          :scopes,
          :prompt,
          settings: [
            :default_role, :scopes, :prompt,
            # SAML settings
            :idp_metadata_url, :idp_sso_url, :idp_slo_url,
            :idp_certificate, :idp_cert_fingerprint, :name_id_format,
            role_mapping: {}
          ]
        )
      end

      # Process params to convert role_mapping comma-separated strings to arrays
      def processed_params
        result = sso_provider_params.to_h

        if result[:settings].present? && result[:settings][:role_mapping].present?
          result[:settings][:role_mapping] = result[:settings][:role_mapping].transform_values do |v|
            # Convert comma-separated string to array, removing empty values
            v.to_s.split(",").map(&:strip).reject(&:blank?)
          end

          # Remove empty role mappings
          result[:settings][:role_mapping] = result[:settings][:role_mapping].reject { |_, v| v.empty? }
          result[:settings].delete(:role_mapping) if result[:settings][:role_mapping].empty?
        end

        result
      end

      def log_provider_change(action, provider)
        Rails.logger.info(
          "[Admin::SsoProviders] #{action.to_s.upcase} - " \
          "user_id=#{Current.user.id} " \
          "provider_id=#{provider.id} " \
          "provider_name=#{provider.name} " \
          "strategy=#{provider.strategy} " \
          "enabled=#{provider.enabled}"
        )
      end

      def clear_provider_cache
        ProviderLoader.clear_cache
        Rails.logger.info("[Admin::SsoProviders] Provider cache cleared by user_id=#{Current.user.id}")
      end
  end
end

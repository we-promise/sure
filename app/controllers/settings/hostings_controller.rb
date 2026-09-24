class Settings::HostingsController < ApplicationController
  layout "settings"

  # Minimum accepted value for each configurable numeric LLM field. Mirrors the
  # `min:` attribute on the form inputs in `_openai_settings.html.erb` so the
  # controller rejects what the browser-side validator would reject.
  LLM_NUMERIC_MINIMUMS = {
    llm_context_window: 256,
    llm_max_response_tokens: 64,
    llm_max_items_per_call: 1,
    openai_request_timeout: Provider::Openai::MIN_REQUEST_TIMEOUT,
    ai_response_timeout: Chat::MIN_RESPONSE_TIMEOUT.to_i
  }.freeze

  guard_feature unless: -> { self_hosted? }

  before_action :ensure_admin, only: [ :update, :clear_cache, :disconnect_external_assistant ]
  before_action :ensure_super_admin_for_onboarding, only: :update

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.self_hosting"), nil ]
    ]

    # Determine which providers are currently selected
    exchange_rate_provider = ENV["EXCHANGE_RATE_PROVIDER"].presence || Setting.exchange_rate_provider
    enabled_securities = Setting.enabled_securities_providers

    # Show provider settings if used for FX or enabled for securities
    @show_twelve_data_settings = exchange_rate_provider == "twelve_data" || enabled_securities.include?("twelve_data")
    @show_yahoo_finance_settings = exchange_rate_provider == "yahoo_finance" || enabled_securities.include?("yahoo_finance")
    @show_tiingo_settings = enabled_securities.include?("tiingo")
    @show_eodhd_settings = enabled_securities.include?("eodhd")
    @show_alpha_vantage_settings = enabled_securities.include?("alpha_vantage")
    @show_mansa_settings = enabled_securities.include?("mansa")
    tinkoff_invest_checked = enabled_securities.include?("tinkoff_invest")
    tinkoff_invest_configured = ENV["TINKOFF_INVEST_API_KEY"].present? || Setting.tinkoff_invest_api_key.present?
    @show_tinkoff_invest_settings = tinkoff_invest_checked || enabled_securities.include?("moex_public") || tinkoff_invest_configured
    @tinkoff_invest_moex_only = @show_tinkoff_invest_settings && !tinkoff_invest_checked

    # Only fetch provider data if we're showing the section
    if @show_twelve_data_settings
      twelve_data_provider = Provider::Registry.get_provider(:twelve_data)
      @twelve_data_usage = twelve_data_provider&.usage
      @plan_restricted_securities = Current.family.securities_with_plan_restrictions(provider: "TwelveData")
    end

    if @show_yahoo_finance_settings
      @yahoo_finance_provider = Provider::Registry.get_provider(:yahoo_finance)
      @yahoo_finance_health_status = @yahoo_finance_provider&.health_status || :unknown
    end

    # Property valuation (AVM) providers — usage is shown against their tight
    # monthly request caps when a key is configured
    @rentcast_usage = Provider::Registry.get_provider(:rentcast)&.usage
    @realie_usage = Provider::Registry.get_provider(:realie)&.usage

    load_external_assistant_models
    load_openai_models
  end

  def update
    if hosting_params.key?(:onboarding_state)
      onboarding_state = hosting_params[:onboarding_state].to_s
      Setting.onboarding_state = onboarding_state
    end

    if hosting_params.key?(:require_email_confirmation)
      Setting.require_email_confirmation = hosting_params[:require_email_confirmation]
    end

    if hosting_params.key?(:invite_only_default_family_id)
      value = hosting_params[:invite_only_default_family_id].presence
      Setting.invite_only_default_family_id = value
    end

    if hosting_params.key?(:brand_fetch_client_id)
      Setting.brand_fetch_client_id = hosting_params[:brand_fetch_client_id]
    end

    if hosting_params.key?(:brand_fetch_high_res_logos)
      Setting.brand_fetch_high_res_logos = hosting_params[:brand_fetch_high_res_logos] == "1"
    end

    update_encrypted_setting(:twelve_data_api_key)

    if hosting_params.key?(:exchange_rate_provider)
      Setting.exchange_rate_provider = hosting_params[:exchange_rate_provider]
    end

    if hosting_params.key?(:securities_provider)
      Setting.securities_provider = hosting_params[:securities_provider]
    end

    if hosting_params.key?(:securities_providers)
      new_providers = Array(hosting_params[:securities_providers]).reject(&:blank?) & Security.valid_price_providers
      old_providers = Setting.enabled_securities_providers

      Setting.securities_providers = new_providers.join(",")

      Setting.securities_provider = "" if new_providers.empty?

      # Mark securities linked to removed providers as offline so they aren't
      # silently queried against an incompatible fallback provider (e.g. MFAPI
      # scheme codes sent to TwelveData). The price_provider is preserved so
      # provider_status can report :provider_unavailable.
      removed = old_providers - new_providers
      removed.each do |removed_provider|
        Security.where(price_provider: removed_provider, offline: false)
                .in_batches.update_all(offline: true, offline_reason: "provider_disabled")
      end

      # Bring securities back online when their provider is re-enabled — but only
      # those that were taken offline by a provider toggle, not by health checks.
      added = new_providers - old_providers
      added.each do |added_provider|
        Security.where(price_provider: added_provider, offline: true, offline_reason: "provider_disabled")
                .in_batches.update_all(offline: false, offline_reason: nil, failed_fetch_count: 0, failed_fetch_at: nil)
      end
    end

    update_encrypted_setting(:tiingo_api_key)
    update_encrypted_setting(:eodhd_api_key)
    update_encrypted_setting(:alpha_vantage_api_key)
    update_encrypted_setting(:tinkoff_invest_api_key)
    update_encrypted_setting(:mansa_api_key)
    update_encrypted_setting(:rentcast_api_key)
    update_encrypted_setting(:realie_api_key)

    if hosting_params.key?(:syncs_include_pending)
      Setting.syncs_include_pending = hosting_params[:syncs_include_pending] == "1"
    end

    sync_settings_changed = false

    if hosting_params.key?(:auto_sync_enabled)
      Setting.auto_sync_enabled = hosting_params[:auto_sync_enabled] == "1"
      sync_settings_changed = true
    end

    if hosting_params.key?(:auto_sync_time)
      time_value = hosting_params[:auto_sync_time]
      unless Setting.valid_auto_sync_time?(time_value)
        flash[:alert] = t(".invalid_sync_time")
        return redirect_to settings_hosting_path
      end

      Setting.auto_sync_time = time_value
      Setting.auto_sync_timezone = current_user_timezone
      sync_settings_changed = true
    end

    if sync_settings_changed
      sync_auto_sync_scheduler!
    end

    update_encrypted_setting(:openai_access_token)

    # Validate OpenAI configuration before updating
    if hosting_params.key?(:openai_uri_base) || hosting_params.key?(:openai_model)
      Setting.validate_openai_config!(
        uri_base: hosting_params[:openai_uri_base],
        model: hosting_params[:openai_model]
      )
    end

    if hosting_params.key?(:openai_uri_base)
      Setting.openai_uri_base = hosting_params[:openai_uri_base]
    end

    if hosting_params.key?(:openai_model)
      Setting.openai_model = hosting_params[:openai_model]
    end

    if hosting_params.key?(:openai_json_mode)
      Setting.openai_json_mode = hosting_params[:openai_json_mode].presence
    end

    update_encrypted_setting(:anthropic_access_token)

    if hosting_params.key?(:anthropic_base_url)
      raw_base_url = hosting_params[:anthropic_base_url].to_s.strip
      if raw_base_url.blank?
        Setting.anthropic_base_url = nil
      else
        parsed = URI.parse(raw_base_url) rescue nil
        unless parsed.is_a?(URI::HTTP)
          raise Setting::ValidationError, t(".invalid_anthropic_base_url")
        end
        # A custom Anthropic-compatible endpoint requires a model — Provider::Anthropic
        # raises without one. Validate the pair together (mirrors the OpenAI branch), using
        # the submitted model when present so a blanked model field is caught too.
        effective_model =
          if hosting_params.key?(:anthropic_model)
            hosting_params[:anthropic_model].to_s.strip
          else
            Setting.anthropic_model.to_s.strip
          end
        if effective_model.blank?
          raise Setting::ValidationError, t(".anthropic_model_required_for_base_url")
        end
        Setting.anthropic_base_url = raw_base_url
      end
    end

    if hosting_params.key?(:anthropic_model)
      Setting.anthropic_model = hosting_params[:anthropic_model].presence
    end

    if hosting_params.key?(:llm_provider)
      provider = hosting_params[:llm_provider].to_s
      if %w[openai anthropic].include?(provider)
        Setting.llm_provider = provider
      end
    end

    update_encrypted_setting(:jev_api_key)

    if hosting_params.key?(:jev_endpoint)
      raw_endpoint = hosting_params[:jev_endpoint].to_s.strip
      if raw_endpoint.blank?
        Setting.jev_endpoint = nil
      else
        # Provider::Jev owns the rule so settings, JEV_ENDPOINT and eval-time
        # construction cannot drift apart; the controller's job is only to turn
        # a rejection into a message instead of a 500.
        unless Provider::Jev.endpoint_allowed?(raw_endpoint)
          raise Setting::ValidationError, t(".invalid_jev_endpoint")
        end
        Setting.jev_endpoint = raw_endpoint
      end
    end

    if hosting_params.key?(:jev_model)
      Setting.jev_model = hosting_params[:jev_model].presence
    end

    LLM_NUMERIC_MINIMUMS.each do |key, minimum|
      next unless hosting_params.key?(key)
      raw = hosting_params[key].to_s.strip
      if raw.blank?
        Setting.public_send("#{key}=", nil)
        next
      end
      parsed = Integer(raw, 10) rescue nil
      if parsed.nil? || parsed < minimum
        label = t("settings.hostings.openai_settings.#{key}_label")
        raise Setting::ValidationError, t(".invalid_llm_budget", field: label, minimum: minimum)
      end
      Setting.public_send("#{key}=", parsed)
    end

    reselect_external_agent = update_external_assistant_settings!

    update_assistant_type
    update_categorization_provider
    update_categorization_tuning

    if reselect_external_agent
      redirect_to settings_hosting_path, alert: t("settings.hostings.assistant_settings.external_agent_reselect")
    else
      redirect_to settings_hosting_path, notice: t(".success")
    end
  rescue Setting::ValidationError => error
    # Preserve user-submitted OpenAI config so the form re-renders with their
    # input intact (issue #1824). The form auto-submits on blur, so a partial
    # entry (e.g. URI base before model) hits validation and would otherwise
    # be wiped because the view reads from the unchanged Setting.* values.
    @openai_uri_base_input = hosting_params[:openai_uri_base] if hosting_params.key?(:openai_uri_base)
    @openai_model_input = hosting_params[:openai_model] if hosting_params.key?(:openai_model)
    @anthropic_base_url_input = hosting_params[:anthropic_base_url] if hosting_params.key?(:anthropic_base_url)
    @anthropic_model_input = hosting_params[:anthropic_model] if hosting_params.key?(:anthropic_model)
    @jev_endpoint_input = hosting_params[:jev_endpoint] if hosting_params.key?(:jev_endpoint)
    @jev_model_input = hosting_params[:jev_model] if hosting_params.key?(:jev_model)
    flash.now[:alert] = error.message
    # Nothing was saved, so reload the agent options from the stored config;
    # otherwise the 422 page shows an empty, disabled agent dropdown.
    load_external_assistant_models
    load_openai_models
    render :show, status: :unprocessable_entity
  end

  def clear_cache
    DataCacheClearJob.perform_later(Current.family)
    redirect_to settings_hosting_path, notice: t(".cache_cleared")
  end

  def disconnect_external_assistant
    Setting.external_assistant_url = nil
    Setting.external_assistant_token = nil
    Setting.external_assistant_model = nil
    Setting.external_assistant_agent_id = nil
    Current.family.update!(assistant_type: "builtin") unless ENV["ASSISTANT_TYPE"].present?
    redirect_to settings_hosting_path, notice: t(".external_assistant_disconnected")
  rescue => e
    Rails.logger.error("[External Assistant] Disconnect failed: #{e.message}")
    redirect_to settings_hosting_path, alert: t("settings.hostings.update.failure")
  end

  private
    # Strong parameters for the self-hosting settings form.
    def hosting_params
      return ActionController::Parameters.new unless params.key?(:setting)
      params.require(:setting).permit(:onboarding_state, :require_email_confirmation, :invite_only_default_family_id, :brand_fetch_client_id, :brand_fetch_high_res_logos, :twelve_data_api_key, :tiingo_api_key, :eodhd_api_key, :alpha_vantage_api_key, :tinkoff_invest_api_key, :mansa_api_key, :rentcast_api_key, :realie_api_key, :openai_access_token, :openai_uri_base, :openai_model, :openai_json_mode, :anthropic_access_token, :anthropic_base_url, :anthropic_model, :jev_api_key, :jev_endpoint, :jev_model, :llm_provider, :llm_context_window, :llm_max_response_tokens, :llm_max_items_per_call, :openai_request_timeout, :ai_response_timeout, :exchange_rate_provider, :securities_provider, :syncs_include_pending, :auto_sync_enabled, :auto_sync_time, :external_assistant_url, :external_assistant_token, :external_assistant_model, securities_providers: [])
    end

    def load_external_assistant_models
      @external_assistant_models = []
      @external_assistant_catalog_error = nil
      effective_type = ENV["ASSISTANT_TYPE"].presence || Current.family.assistant_type
      return unless effective_type == "external"

      config = Assistant::External.config
      return unless config.url.present? && config.token.present?

      # Rendered synchronously, so keep a stalled gateway from holding the page.
      @external_assistant_models = Assistant::External::ModelCatalog.new(
        url: config.url,
        token: config.token,
        open_timeout: 3,
        read_timeout: 5
      ).models
    rescue Assistant::External::ModelCatalog::Error => error
      @external_assistant_catalog_error = error.message
    end

    # Suggests model ids for a custom OpenAI-compatible endpoint (OpenRouter,
    # Ollama, LiteLLM, ...). Only runs when a custom base URL is set: the model
    # field stays free text, so a failed or empty listing never blocks saving.
    # On a rejected update, list from the URL the admin just typed.
    def load_openai_models
      @openai_models = []
      @openai_models_error = nil

      uri_base = ENV["OPENAI_URI_BASE"].presence || @openai_uri_base_input.presence || Setting.openai_uri_base
      return if uri_base.blank?

      @openai_models = Provider::Openai::ModelCatalog.new(
        uri_base: uri_base,
        token: ENV["OPENAI_ACCESS_TOKEN"].presence || Setting.openai_access_token,
        open_timeout: 3,
        read_timeout: 5
      ).models
    rescue Provider::Openai::ModelCatalog::Error => error
      @openai_models_error = error
    end

    # Validates the submitted endpoint, token and agent together before any of
    # them is written, so a rejected change leaves the stored config untouched.
    # Returns true when the connection changed and the old agent must be reselected.
    def update_external_assistant_settings!
      keys = %i[external_assistant_url external_assistant_token external_assistant_model]
      return false unless keys.any? { |key| hosting_params.key?(key) }

      current = Assistant::External.config
      url = ENV["EXTERNAL_ASSISTANT_URL"].presence || submitted_external_assistant_url(current.url)
      token = ENV["EXTERNAL_ASSISTANT_TOKEN"].presence || submitted_external_assistant_token(current.token)
      connection_changed = url != current.url || token != current.token

      model_submitted = hosting_params.key?(:external_assistant_model)
      model = model_submitted ? hosting_params[:external_assistant_model].presence : Setting.external_assistant_model.presence
      raise Setting::ValidationError, t("settings.hostings.assistant_settings.external_agent_required") if model_submitted && model.blank?

      reselect = false
      if model_submitted
        unless external_assistant_model_ids(url, token).include?(model)
          raise Setting::ValidationError, t("settings.hostings.assistant_settings.external_agent_invalid") unless connection_changed

          # The agent list on the page came from the previous connection. Save
          # the new connection, but never pair it with an agent it does not offer.
          model = nil
          reselect = true
        end
      elsif connection_changed && model.present? && ENV["EXTERNAL_ASSISTANT_MODEL"].blank?
        available = begin
          external_assistant_model_ids(url, token)
        rescue Setting::ValidationError
          []
        end
        unless available.include?(model)
          model = nil
          reselect = true
        end
      end

      Setting.transaction do
        Setting.external_assistant_url = hosting_params[:external_assistant_url] if hosting_params.key?(:external_assistant_url)
        update_encrypted_setting(:external_assistant_token)
        if model_submitted || reselect
          Setting.external_assistant_model = model
          Setting.external_assistant_agent_id = nil
        end
      end

      reselect
    end

    def submitted_external_assistant_url(current_url)
      return current_url unless hosting_params.key?(:external_assistant_url)

      hosting_params[:external_assistant_url].presence
    end

    def submitted_external_assistant_token(current_token)
      return current_token unless hosting_params.key?(:external_assistant_token)

      value = hosting_params[:external_assistant_token].to_s.strip
      value == "********" ? current_token : value.presence
    end

    def external_assistant_model_ids(url, token)
      Assistant::External::ModelCatalog.new(url: url, token: token).models.pluck(:id)
    rescue Assistant::External::ModelCatalog::Error => error
      raise Setting::ValidationError, t("settings.hostings.assistant_settings.agent_discovery_error", error: error.message)
    end

    # Family-scoped, like assistant_type: it decides whose transaction data is
    # sent to Jev. Guarded by the preview gate because the selector that submits
    # it is only rendered for opted-in users.
    def update_categorization_provider
      return unless params[:family].present? && params[:family][:categorization_provider].present?
      return if ENV["CATEGORIZATION_PROVIDER"].present?
      return unless preview_features_enabled?

      provider = params[:family][:categorization_provider]
      return unless Family::CATEGORIZATION_PROVIDERS.include?(provider)

      Current.family.update!(categorization_provider: provider)
    end

    # Family-scoped like categorization_provider. Validated here rather than
    # leaning on the DB check constraint, which would surface as a 500 instead
    # of the inline error the rest of this form gives.
    def update_categorization_tuning
      return unless params[:family].present?
      return unless preview_features_enabled?

      updates = {}

      if params[:family][:categorization_confidence_threshold].present? && ENV["CATEGORIZATION_CONFIDENCE_THRESHOLD"].blank?
        updates[:categorization_confidence_threshold] = unit_interval!(
          params[:family][:categorization_confidence_threshold],
          t("settings.hostings.categorization_provider_selector.confidence_threshold_label")
        )
      end

      if params[:family][:categorization_shadow_rate].present? && ENV["CATEGORIZATION_SHADOW_RATE"].blank?
        updates[:categorization_shadow_rate] = unit_interval!(
          params[:family][:categorization_shadow_rate],
          t("settings.hostings.categorization_provider_selector.shadow_rate_label")
        )
      end

      Current.family.update!(updates) if updates.any?
    end

    def unit_interval!(raw, field_label)
      value = Float(raw.to_s.strip) rescue nil

      if value.nil? || value.negative? || value > 1
        raise Setting::ValidationError,
              t("settings.hostings.update.invalid_categorization_rate", field: field_label)
      end

      value
    end

    def update_assistant_type
      return unless params[:family].present? && params[:family][:assistant_type].present?
      return if ENV["ASSISTANT_TYPE"].present?

      assistant_type = params[:family][:assistant_type]
      Current.family.update!(assistant_type: assistant_type) if Family::ASSISTANT_TYPES.include?(assistant_type)
    end

    def ensure_admin
      redirect_to settings_hosting_path, alert: t(".not_authorized") unless Current.user.admin?
    end

    def ensure_super_admin_for_onboarding
      onboarding_params = %i[onboarding_state invite_only_default_family_id]
      return unless onboarding_params.any? { |p| hosting_params.key?(p) }
      redirect_to settings_hosting_path, alert: t(".not_authorized") unless Current.user.super_admin?
    end

    def sync_auto_sync_scheduler!
      AutoSyncScheduler.sync!
    rescue StandardError => error
      Rails.logger.error("[AutoSyncScheduler] Failed to sync scheduler: #{error.message}")
      Rails.logger.error(error.backtrace.join("\n"))
      flash[:alert] = t(".scheduler_sync_failed")
    end

    def update_encrypted_setting(param_key)
      return unless hosting_params.key?(param_key)
      value = hosting_params[param_key].to_s.strip

      # "********" is the masked placeholder rendered for an existing key; it
      # means "leave the stored value untouched". A blank submission, however,
      # is an explicit request to clear the key, so persist nil in that case.
      return if value == "********"

      Setting.public_send(:"#{param_key}=", value.presence)
    end

    def current_user_timezone
      Current.family&.timezone.presence || "UTC"
    end
end

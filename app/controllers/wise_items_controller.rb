# frozen_string_literal: true

class WiseItemsController < ApplicationController
  before_action :set_wise_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, except: [ :index ]

  def index
    @wise_items = Current.family.wise_items.active.ordered
    render layout: "settings"
  end

  def show
  end

  def new
    @wise_item = Current.family.wise_items.build
  end

  # Step 1: Validate token and fetch profiles, then proceed to profile selection.
  def create
    token = wise_item_token_param # pipelock:ignore

    if token.blank?
      @wise_item = Current.family.wise_items.build
      @wise_item.errors.add(:token, :blank)
      return render_provider_panel_error
    end

    provider = Provider::Wise.new(token, base_url: Rails.configuration.x.wise.base_url)
    profiles = provider.get_profiles

    if profiles.blank?
      @wise_item = Current.family.wise_items.build
      @wise_item.errors.add(:base, t(".no_profiles_found"))
      return render_provider_panel_error
    end

    session[:wise_pending_profiles] = profiles
    session[:wise_pending_encrypted_token] = encrypt_pending_token(token)

    redirect_to select_profiles_wise_items_path
  rescue Provider::Wise::WiseError => e
    @wise_item = Current.family.wise_items.build
    error_key = e.error_type == :unauthorized ? ".invalid_token" : ".connection_failed"
    @wise_item.errors.add(:base, t(error_key))
    render_provider_panel_error
  end

  # Step 2: Show profile selection.
  def select_profiles
    @pending_profiles = session[:wise_pending_profiles]
    @encrypted_pending_token = session[:wise_pending_encrypted_token]

    if @pending_profiles.blank? || @encrypted_pending_token.blank?
      redirect_to settings_providers_path, alert: t(".session_expired") and return
    end

    @existing_profile_ids = Current.family.wise_items.pluck(:profile_id).map(&:to_s).to_set
  end

  # Step 3: Create one WiseItem per selected profile.
  def link_profiles
    token = decrypt_pending_token(session[:wise_pending_encrypted_token]) # pipelock:ignore
    profiles = session[:wise_pending_profiles]

    if token.blank? || profiles.blank?
      redirect_to settings_providers_path, alert: t(".session_expired") and return
    end

    selected_ids = Array(params[:profile_ids]).map(&:to_s).compact_blank
    if selected_ids.empty?
      redirect_to select_profiles_wise_items_path, alert: t(".no_profiles_selected") and return
    end

    created = 0
    profiles.each do |profile|
      profile_id = profile["id"].to_s
      next unless selected_ids.include?(profile_id)
      next if Current.family.wise_items.exists?(profile_id: profile_id)

      profile_type = profile["type"] == "business" ? "business" : "personal"
      display_name = profile_display_name(profile)

      Current.family.create_wise_item!(
        token: token,
        profile_id: profile_id,
        profile_type: profile_type,
        item_name: display_name
      )
      created += 1
    end

    session.delete(:wise_pending_profiles)
    session.delete(:wise_pending_encrypted_token)

    if created.zero?
      redirect_to settings_providers_path, alert: t(".already_connected")
    else
      redirect_to settings_providers_path, notice: t(".success", count: created)
    end
  end

  def edit
  end

  def update
    permitted = wise_item_update_params
    if @wise_item.update(permitted)
      render_provider_panel_success(t(".success"))
    else
      render_provider_panel_error
    end
  end

  def destroy
    @wise_item.unlink_all!(dry_run: false)
    @wise_item.destroy_later
    redirect_to accounts_path, notice: t(".success")
  end

  def sync
    @wise_item.sync_later unless @wise_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def setup_accounts
    @wise_accounts = @wise_item.wise_accounts.unlinked
  end

  def complete_account_setup
    wise_account_id = params[:wise_account_id]
    wise_account = @wise_item.wise_accounts.find_by(id: wise_account_id)

    unless wise_account
      redirect_to accounts_path, alert: t(".not_found") and return
    end

    account = Account.create_from_wise_account(wise_account)

    AccountProvider.create!(
      account: account,
      provider: wise_account
    )

    @wise_item.sync_later unless @wise_item.syncing?

    redirect_to accounts_path, notice: t(".success")
  rescue => e
    Rails.logger.error "WiseItemsController#complete_account_setup - #{e.class}: #{e.message}"
    redirect_to setup_accounts_wise_item_path(@wise_item), alert: t(".failed")
  end

  # Collection actions for provider-panel account linking flow

  def select_accounts
    @accountable_type = params[:accountable_type] || "Depository"
    @return_to = safe_return_to_path
    @wise_item = resolve_wise_item_for_selection

    unless @wise_item
      redirect_to settings_providers_path, alert: t("wise_items.select_accounts.no_connection") and return
    end

    @available_accounts = @wise_item.wise_accounts.unlinked

    render layout: false
  end

  def link_accounts
    wise_account = find_wise_account_for_linking(params[:wise_account_id])

    unless wise_account
      redirect_to safe_return_to_path || accounts_path, alert: t("wise_items.link_accounts.not_found") and return
    end

    account = Account.create_from_wise_account(wise_account)
    AccountProvider.create!(account: account, provider: wise_account)
    wise_account.wise_item.sync_later unless wise_account.wise_item.syncing?

    redirect_to safe_return_to_path || accounts_path, notice: t("wise_items.link_accounts.success")
  rescue => e
    Rails.logger.error "WiseItemsController#link_accounts - #{e.class}: #{e.message}"
    redirect_to safe_return_to_path || accounts_path, alert: t("wise_items.link_accounts.failed")
  end

  def select_existing_account
    @account = Current.family.accounts.find_by(id: params[:account_id])
    @return_to = safe_return_to_path
    @wise_item = resolve_wise_item_for_selection

    unless @account && @wise_item
      redirect_to accounts_path, alert: t("wise_items.select_existing_account.not_found") and return
    end

    @available_accounts = @wise_item.wise_accounts.unlinked

    render layout: false
  end

  def link_existing_account
    account = Current.family.accounts.find_by(id: params[:account_id])
    wise_account = find_wise_account_for_linking(params[:wise_account_id])

    unless account && wise_account
      redirect_to accounts_path, alert: t("wise_items.link_existing_account.not_found") and return
    end

    AccountProvider.create!(account: account, provider: wise_account)
    wise_account.wise_item.sync_later unless wise_account.wise_item.syncing?

    redirect_to safe_return_to_path || accounts_path, notice: t("wise_items.link_existing_account.success", account_name: account.name)
  rescue => e
    Rails.logger.error "WiseItemsController#link_existing_account - #{e.class}: #{e.message}"
    redirect_to accounts_path, alert: t("wise_items.link_existing_account.failed")
  end

  private

    def set_wise_item
      @wise_item = Current.family.wise_items.find(params[:id])
    end

    def wise_item_token_param
      params.dig(:wise_item, :token).to_s.strip
    end

    def wise_item_update_params
      permitted = params.require(:wise_item).permit(:name, :sync_start_date, :token)
      permitted.delete(:token) if @wise_item.persisted? && permitted[:token].blank?
      permitted[:token] = permitted[:token].to_s.strip if permitted[:token].present?
      permitted
    end

    def resolve_wise_item_for_selection
      wise_item_id = params[:wise_item_id]

      if wise_item_id.present?
        Current.family.wise_items.active.find_by(id: wise_item_id)
      else
        Current.family.wise_items.active.ordered.first
      end
    end

    def find_wise_account_for_linking(wise_account_id)
      return nil if wise_account_id.blank?

      WiseAccount.joins(:wise_item)
                 .merge(Current.family.wise_items.active)
                 .find_by(id: wise_account_id)
    end

    def profile_display_name(profile)
      type_key = profile["type"] == "business" ? :business : :personal
      type_label = I18n.t("wise_items.profile_types.#{type_key}")
      details = profile["details"] || {}
      name = details["name"].presence ||
             [ details["firstName"], details["lastName"] ].compact.join(" ").presence

      name.present? ? "#{name} (#{type_label})" : "Wise #{type_label}"
    end

    def render_provider_panel_success(message)
      return redirect_to accounts_path, notice: message, status: :see_other unless turbo_frame_request?

      flash.now[:notice] = message
      @wise_items = Current.family.wise_items.active.ordered.includes(:syncs, :wise_accounts)
      render_wise_provider_panel(locals: { wise_items: @wise_items }, include_flash: true)
    end

    def render_provider_panel_error
      @error_message = @wise_item.errors.full_messages.join(", ")
      return redirect_to settings_providers_path, alert: @error_message, status: :see_other unless turbo_frame_request?

      render_wise_provider_panel(locals: { error_message: @error_message }, status: :unprocessable_entity)
    end

    def render_wise_provider_panel(locals:, status: :ok, include_flash: false)
      streams = [
        turbo_stream.replace(
          "wise-providers-panel",
          partial: "settings/providers/wise_panel",
          locals: locals
        )
      ]
      streams += flash_notification_stream_items if include_flash
      render turbo_stream: streams, status: status
    end

    def encrypt_pending_token(token)
      build_token_encryptor.encrypt_and_sign(token, expires_in: 15.minutes)
    end

    def decrypt_pending_token(encrypted)
      return nil if encrypted.blank?
      build_token_encryptor.decrypt_and_verify(encrypted)
    rescue ActiveSupport::MessageEncryptor::InvalidMessage, ArgumentError
      nil
    end

    def build_token_encryptor
      key = Rails.application.key_generator.generate_key("wise_pending_token", 32)
      ActiveSupport::MessageEncryptor.new(key)
    end

    def safe_return_to_path
      return nil if params[:return_to].blank?

      return_to = params[:return_to].to_s.strip
      return nil unless return_to.start_with?("/")

      second_char = return_to[1]
      return nil if second_char.blank? || second_char == "/" || second_char == "\\"
      return nil if second_char.match?(/[[:space:][:cntrl:]]/)

      uri = URI.parse(return_to)
      return nil if uri.scheme.present? || uri.host.present?

      return_to
    rescue URI::InvalidURIError
      nil
    end
end

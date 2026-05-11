# frozen_string_literal: true

class KrakenItemsController < ApplicationController
  before_action :set_kraken_item, only: %i[update destroy sync setup_accounts complete_account_setup]
  before_action :require_admin!, only: %i[create select_accounts link_accounts select_existing_account link_existing_account update destroy sync setup_accounts complete_account_setup]

  def create
    @kraken_item = Current.family.kraken_items.build(kraken_item_params)
    @kraken_item.name ||= t(".default_name")

    if @kraken_item.save
      @kraken_item.set_kraken_institution_defaults!
      @kraken_item.sync_later
      render_panel_success(t(".success"))
    else
      render_panel_error(@kraken_item.errors.full_messages.join(", "))
    end
  end

  def update
    if @kraken_item.update(kraken_item_params)
      render_panel_success(t(".success"))
    else
      render_panel_error(@kraken_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    @kraken_item.unlink_all!(dry_run: false)
    @kraken_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success")
  end

  def sync
    @kraken_item.sync_later unless @kraken_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to settings_providers_path }
      format.json { head :ok }
    end
  end

  def select_accounts
    account_flow = kraken_item_account_flow_context
    kraken_item = account_flow[:kraken_item]

    unless kraken_item
      redirect_to settings_providers_path, alert: kraken_item_selection_message(account_flow[:credentialed_items])
      return
    end

    redirect_to setup_accounts_kraken_item_path(kraken_item, return_to: safe_return_to_path), status: :see_other
  end

  def link_accounts
    kraken_item = kraken_item_account_flow_context[:kraken_item]
    unless kraken_item
      redirect_to settings_providers_path, alert: t(".select_connection")
      return
    end

    redirect_to setup_accounts_kraken_item_path(kraken_item), status: :see_other
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    account_flow = kraken_item_account_flow_context
    @kraken_item = account_flow[:kraken_item]

    unless manual_crypto_exchange_account?(@account)
      redirect_to accounts_path, alert: t("kraken_items.link_existing_account.errors.only_manual")
      return
    end

    unless @kraken_item
      redirect_to settings_providers_path, alert: kraken_item_selection_message(account_flow[:credentialed_items])
      return
    end

    @available_kraken_accounts = @kraken_item.kraken_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .order(:name)

    render :select_existing_account, layout: false
  end

  def link_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    kraken_item = kraken_item_account_flow_context[:kraken_item]

    unless manual_crypto_exchange_account?(@account)
      return redirect_or_flash_error(t(".errors.only_manual"), account_path(@account))
    end

    unless kraken_item
      redirect_to settings_providers_path, alert: t(".select_connection")
      return
    end

    kraken_account = kraken_item.kraken_accounts.find_by(id: params[:kraken_account_id])
    unless kraken_account
      return redirect_or_flash_error(t(".errors.invalid_kraken_account"), account_path(@account))
    end
    if kraken_account.account_provider.present?
      return redirect_or_flash_error(t(".errors.kraken_account_already_linked"), account_path(@account))
    end

    AccountProvider.create!(account: @account, provider: kraken_account)
    kraken_item.sync_later

    redirect_to accounts_path, notice: t(".success")
  end

  def setup_accounts
    @kraken_accounts = unlinked_accounts_for(@kraken_item)
  end

  def complete_account_setup
    selected_accounts = Array(params[:selected_accounts]).reject(&:blank?)
    created_accounts = []

    selected_accounts.each do |kraken_account_id|
      kraken_account = @kraken_item.kraken_accounts.find_by(id: kraken_account_id)
      next unless kraken_account

      kraken_account.with_lock do
        next if kraken_account.account_provider.present?

        account = Account.create_from_kraken_account(kraken_account)
        provider_link = kraken_account.ensure_account_provider!(account)
        provider_link ? created_accounts << account : account.destroy!
      end

      KrakenAccount::Processor.new(kraken_account.reload).process
    rescue StandardError => e
      Rails.logger.error("Failed to setup account for KrakenAccount #{kraken_account_id}: #{e.message}")
    end

    @kraken_item.update!(pending_account_setup: unlinked_accounts_for(@kraken_item).exists?)
    @kraken_item.sync_later if created_accounts.any?

    notice = if created_accounts.any?
      t(".success", count: created_accounts.count)
    elsif selected_accounts.empty?
      t(".none_selected")
    else
      t(".no_accounts")
    end

    redirect_to accounts_path, notice: notice, status: :see_other
  end

  private

    def set_kraken_item
      @kraken_item = Current.family.kraken_items.find(params[:id])
    end

    def kraken_item_params
      permitted = params.require(:kraken_item).permit(:name, :sync_start_date, :api_key, :api_secret)
      if @kraken_item&.persisted?
        permitted.delete(:api_key) if permitted[:api_key].blank?
        permitted.delete(:api_secret) if permitted[:api_secret].blank?
      end
      permitted
    end

    def render_panel_success(message)
      if turbo_frame_request?
        flash.now[:notice] = message
        @kraken_items = Current.family.kraken_items.active.ordered
        stream = turbo_stream.update("kraken-providers-panel", partial: "settings/providers/kraken_panel", locals: { kraken_items: @kraken_items })
        render turbo_stream: [ stream, *flash_notification_stream_items ]
      else
        redirect_to settings_providers_path, notice: message, status: :see_other
      end
    end

    def render_panel_error(message)
      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "kraken-providers-panel",
          partial: "settings/providers/kraken_panel",
          locals: { error_message: message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: message, status: :see_other
      end
    end

    def kraken_item_account_flow_context
      credentialed_items = Current.family.kraken_items.active.credentials_configured.ordered.select(&:credentials_configured?)
      item = if params[:kraken_item_id].present?
        credentialed_items.find { |candidate| candidate.id.to_s == params[:kraken_item_id].to_s }
      elsif credentialed_items.one?
        credentialed_items.first
      end

      { kraken_item: item, credentialed_items: credentialed_items }
    end

    def unlinked_accounts_for(kraken_item)
      kraken_item.kraken_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).order(:name)
    end

    def kraken_item_selection_message(credentialed_items)
      if credentialed_items.count > 1 && params[:kraken_item_id].blank?
        t("kraken_items.select_accounts.select_connection")
      else
        t("kraken_items.select_accounts.no_credentials_configured")
      end
    end

    def manual_crypto_exchange_account?(account)
      account.manual_crypto_exchange?
    end

    def redirect_or_flash_error(message, fallback_path)
      if turbo_frame_request?
        flash.now[:alert] = message
        render turbo_stream: Array(flash_notification_stream_items)
      else
        redirect_to fallback_path, alert: message
      end
    end

    def safe_return_to_path
      return nil if params[:return_to].blank?

      value = params[:return_to].to_s
      uri = URI.parse(value)
      return nil if uri.scheme.present?
      return nil if uri.host.present?
      return nil unless value.start_with?("/")

      value
    rescue URI::InvalidURIError
      nil
    end
end

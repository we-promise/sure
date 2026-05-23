# frozen_string_literal: true

class BitstampItemsController < ApplicationController
  before_action :set_bitstamp_item, only: %i[update destroy sync setup_accounts complete_account_setup]
  before_action :require_admin!, only: %i[create select_accounts link_accounts select_existing_account link_existing_account update destroy sync setup_accounts complete_account_setup]

  def create
    @bitstamp_item = Current.family.bitstamp_items.build(bitstamp_item_params)
    @bitstamp_item.name ||= t(".default_name")

    if @bitstamp_item.save
      @bitstamp_item.set_bitstamp_institution_defaults!
      @bitstamp_item.sync_later
      render_panel_success(t(".success"))
    else
      render_panel_error(@bitstamp_item.errors.full_messages.join(", "))
    end
  end

  def update
    if @bitstamp_item.update(bitstamp_item_params)
      render_panel_success(t(".success"))
    else
      render_panel_error(@bitstamp_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    @bitstamp_item.unlink_all!(dry_run: false)
    @bitstamp_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success")
  end

  def sync
    @bitstamp_item.sync_later unless @bitstamp_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to settings_providers_path }
      format.json { head :ok }
    end
  end

  def select_accounts
    account_flow = bitstamp_item_account_flow_context
    bitstamp_item = account_flow[:bitstamp_item]

    unless bitstamp_item
      redirect_to settings_providers_path, alert: bitstamp_item_selection_message(account_flow[:credentialed_items])
      return
    end

    redirect_to setup_accounts_bitstamp_item_path(bitstamp_item, return_to: safe_return_to_path), status: :see_other
  end

  def link_accounts
    bitstamp_item = bitstamp_item_account_flow_context[:bitstamp_item]
    unless bitstamp_item
      redirect_to settings_providers_path, alert: t(".select_connection")
      return
    end

    redirect_to setup_accounts_bitstamp_item_path(bitstamp_item), status: :see_other
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    account_flow = bitstamp_item_account_flow_context
    @bitstamp_item = account_flow[:bitstamp_item]

    unless manual_crypto_exchange_account?(@account)
      redirect_to accounts_path, alert: t("bitstamp_items.link_existing_account.errors.only_manual")
      return
    end

    unless @bitstamp_item
      redirect_to settings_providers_path, alert: bitstamp_item_selection_message(account_flow[:credentialed_items])
      return
    end

    @available_bitstamp_accounts = @bitstamp_item.bitstamp_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .order(:name)

    render :select_existing_account, layout: false
  end

  def link_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    bitstamp_item = bitstamp_item_account_flow_context[:bitstamp_item]

    unless manual_crypto_exchange_account?(@account)
      return redirect_or_flash_error(t(".errors.only_manual"), account_path(@account))
    end

    unless bitstamp_item
      redirect_to settings_providers_path, alert: t(".select_connection")
      return
    end

    bitstamp_account = bitstamp_item.bitstamp_accounts.find_by(id: params[:bitstamp_account_id])
    unless bitstamp_account
      return redirect_or_flash_error(t(".errors.invalid_bitstamp_account"), account_path(@account))
    end
    if bitstamp_account.account_provider.present?
      return redirect_or_flash_error(t(".errors.bitstamp_account_already_linked"), account_path(@account))
    end

    AccountProvider.create!(account: @account, provider: bitstamp_account)
    bitstamp_item.sync_later

    redirect_to accounts_path, notice: t(".success")
  end

  def setup_accounts
    @bitstamp_accounts = unlinked_accounts_for(@bitstamp_item)
  end

  def complete_account_setup
    selected_accounts = Array(params[:selected_accounts]).reject(&:blank?)
    created_accounts = []

    selected_accounts.each do |bitstamp_account_id|
      bitstamp_account = @bitstamp_item.bitstamp_accounts.find_by(id: bitstamp_account_id)
      next unless bitstamp_account

      bitstamp_account.with_lock do
        next if bitstamp_account.account_provider.present?

        account = Account.create_from_bitstamp_account(bitstamp_account)
        provider_link = bitstamp_account.ensure_account_provider!(account)
        provider_link ? created_accounts << account : account.destroy!
      end

      BitstampAccount::Processor.new(bitstamp_account.reload).process
    rescue StandardError => e
      Rails.logger.error("Failed to setup account for BitstampAccount #{bitstamp_account_id}: #{e.message}")
    end

    @bitstamp_item.update!(pending_account_setup: unlinked_accounts_for(@bitstamp_item).exists?)
    @bitstamp_item.sync_later if created_accounts.any?

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

    def set_bitstamp_item
      @bitstamp_item = Current.family.bitstamp_items.find(params[:id])
    end

    def bitstamp_item_params
      permitted = params.require(:bitstamp_item).permit(:name, :sync_start_date, :api_key, :api_secret)
      if @bitstamp_item&.persisted?
        permitted.delete(:api_key) if permitted[:api_key].blank?
        permitted.delete(:api_secret) if permitted[:api_secret].blank?
      end
      permitted
    end

    def render_panel_success(message)
      if turbo_frame_request?
        flash.now[:notice] = message
        @bitstamp_items = Current.family.bitstamp_items.active.ordered
        stream = turbo_stream.update("bitstamp-providers-panel", partial: "settings/providers/bitstamp_panel", locals: { bitstamp_items: @bitstamp_items })
        render turbo_stream: [ stream, *flash_notification_stream_items ]
      else
        redirect_to settings_providers_path, notice: message, status: :see_other
      end
    end

    def render_panel_error(message)
      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "bitstamp-providers-panel",
          partial: "settings/providers/bitstamp_panel",
          locals: { error_message: message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: message, status: :see_other
      end
    end

    def bitstamp_item_account_flow_context
      credentialed_items = Current.family.bitstamp_items.active.credentials_configured.ordered.select(&:credentials_configured?)
      item = if params[:bitstamp_item_id].present?
        credentialed_items.find { |candidate| candidate.id.to_s == params[:bitstamp_item_id].to_s }
      elsif credentialed_items.one?
        credentialed_items.first
      end

      { bitstamp_item: item, credentialed_items: credentialed_items }
    end

    def unlinked_accounts_for(bitstamp_item)
      bitstamp_item.bitstamp_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).order(:name)
    end

    def bitstamp_item_selection_message(credentialed_items)
      if credentialed_items.count > 1 && params[:bitstamp_item_id].blank?
        t("bitstamp_items.select_accounts.select_connection")
      else
        t("bitstamp_items.select_accounts.no_credentials_configured")
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

# frozen_string_literal: true

class RevolutXItemsController < ApplicationController
  before_action :set_revolut_x_item, only: %i[update destroy sync setup_accounts complete_account_setup]
  before_action :require_admin!, only: %i[create select_accounts link_accounts select_existing_account link_existing_account update destroy sync setup_accounts complete_account_setup]

  # No sync yet: the API key only exists once the user has registered the
  # connection's public key with Revolut X and pasted the key back.
  def create
    @revolut_x_item = Current.family.revolut_x_items.build(revolut_x_item_params.slice(:name, :private_key))
    @revolut_x_item.name = t(".default_name") if @revolut_x_item.name.blank?

    if @revolut_x_item.save
      @revolut_x_item.set_revolut_x_institution_defaults!
      redirect_to settings_providers_path, notice: t(".success"), status: :see_other
    else
      render_provider_panel("revolut_x", alert: @revolut_x_item.errors.full_messages.join(", "))
    end
  end

  def update
    was_configured = @revolut_x_item.credentials_configured?

    if @revolut_x_item.update(revolut_x_item_params)
      @revolut_x_item.sync_later if !was_configured && @revolut_x_item.credentials_configured?
      render_provider_panel("revolut_x", notice: t(".success"))
    else
      render_provider_panel("revolut_x", alert: @revolut_x_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    # unlink_all! reports a per-account failure on its result instead of
    # raising; deleting anyway would take still-linked accounts' links with it.
    unlink_results = @revolut_x_item.unlink_all!(dry_run: false)
    if unlink_results.any? { |result| result[:error].present? }
      redirect_to settings_providers_path, alert: t(".unlink_failed")
      return
    end

    @revolut_x_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success")
  end

  def sync
    @revolut_x_item.sync_later unless @revolut_x_item.syncing?
    return render_provider_panel("revolut_x", notice: t("settings.providers.sync_provider_in_progress")) if provider_panel_form?

    respond_to do |format|
      format.html { redirect_back_or_to settings_providers_path }
      format.json { head :ok }
    end
  end

  def select_accounts
    account_flow = account_flow_context
    revolut_x_item = account_flow[:revolut_x_item]

    unless revolut_x_item
      frame_redirect_to(settings_providers_path, alert: selection_message(account_flow[:credentialed_items]))
      return
    end

    redirect_to setup_accounts_revolut_x_item_path(revolut_x_item), status: :see_other
  end

  def link_accounts
    revolut_x_item = account_flow_context[:revolut_x_item]
    unless revolut_x_item
      redirect_to settings_providers_path, alert: t(".select_connection")
      return
    end

    redirect_to setup_accounts_revolut_x_item_path(revolut_x_item), status: :see_other
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    # require_admin! is a family-role check, not an account one: an admin who
    # neither owns this account nor holds full_control on it still reaches
    # here. auto_share_with_family! only grants members read_write, so without
    # this the dialog exposes a co-member's account to be linked.
    return unless require_account_permission!(@account, :write, redirect_path: accounts_path)

    account_flow = account_flow_context
    @revolut_x_item = account_flow[:revolut_x_item]

    unless @account.manual_crypto_exchange?
      redirect_to accounts_path, alert: t("revolut_x_items.link_existing_account.errors.only_manual")
      return
    end

    unless @revolut_x_item
      redirect_to settings_providers_path, alert: selection_message(account_flow[:credentialed_items])
      return
    end

    @available_revolut_x_accounts = unlinked_accounts_for(@revolut_x_item)

    render :select_existing_account, layout: false
  end

  def link_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    # Must precede the AccountProvider.create! below: family scoping alone
    # would let an admin attach a provider to a co-member's account they only
    # hold read_write on. Same guard as select_existing_account.
    return unless require_account_permission!(@account, :write, redirect_path: accounts_path)

    revolut_x_item = account_flow_context[:revolut_x_item]

    unless @account.manual_crypto_exchange?
      return redirect_or_flash_error(t(".errors.only_manual"), account_path(@account))
    end

    unless revolut_x_item
      redirect_to settings_providers_path, alert: t(".select_connection")
      return
    end

    revolut_x_account = revolut_x_item.revolut_x_accounts.find_by(id: params[:revolut_x_account_id])
    unless revolut_x_account
      return redirect_or_flash_error(t(".errors.invalid_revolut_x_account"), account_path(@account))
    end
    if revolut_x_account.account_provider.present?
      return redirect_or_flash_error(t(".errors.revolut_x_account_already_linked"), account_path(@account))
    end

    AccountProvider.create!(account: @account, provider: revolut_x_account)
    revolut_x_item.sync_later

    redirect_to accounts_path, notice: t(".success")
  end

  def setup_accounts
    @revolut_x_accounts = unlinked_accounts_for(@revolut_x_item)
  end

  def complete_account_setup
    selected_accounts = Array(params[:selected_accounts]).reject(&:blank?)
    created_accounts = []

    selected_accounts.each do |revolut_x_account_id|
      revolut_x_account = @revolut_x_item.revolut_x_accounts.find_by(id: revolut_x_account_id)
      next unless revolut_x_account

      revolut_x_account.with_lock do
        next if revolut_x_account.account_provider.present?

        account = Account.create_from_revolut_x_account(revolut_x_account)
        AccountProvider.create!(account: account, provider: revolut_x_account)
        created_accounts << account
      end

      RevolutXAccount::Processor.new(revolut_x_account.reload).process
    rescue StandardError => e
      Rails.logger.error("Failed to setup account for RevolutXAccount #{revolut_x_account_id}: #{e.message}")
    end

    @revolut_x_item.update!(pending_account_setup: unlinked_accounts_for(@revolut_x_item).exists?)
    @revolut_x_item.sync_later if created_accounts.any?

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

    def set_revolut_x_item
      @revolut_x_item = Current.family.revolut_x_items.find(params[:id])
    end

    # A blank key field keeps the stored key: neither key is ever sent back to
    # the form, so an untouched field arrives empty.
    def revolut_x_item_params
      permitted = params.require(:revolut_x_item).permit(:name, :sync_start_date, :api_key, :private_key)
      permitted.delete(:api_key) if permitted[:api_key].blank?
      permitted.delete(:private_key) if permitted[:private_key].blank?
      permitted
    end

    def account_flow_context
      credentialed_items = Current.family.revolut_x_items.syncable.ordered.select(&:credentials_configured?)
      item = if params[:revolut_x_item_id].present?
        credentialed_items.find { |candidate| candidate.id.to_s == params[:revolut_x_item_id].to_s }
      elsif credentialed_items.one?
        credentialed_items.first
      end

      { revolut_x_item: item, credentialed_items: credentialed_items }
    end

    def unlinked_accounts_for(revolut_x_item)
      revolut_x_item.revolut_x_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).order(:name)
    end

    def selection_message(credentialed_items)
      if credentialed_items.count > 1 && params[:revolut_x_item_id].blank?
        t("revolut_x_items.select_accounts.select_connection")
      else
        t("revolut_x_items.select_accounts.no_credentials_configured")
      end
    end

    def redirect_or_flash_error(message, fallback_path)
      if turbo_frame_request?
        flash.now[:alert] = message
        render turbo_stream: Array(flash_notification_stream_items)
      else
        redirect_to fallback_path, alert: message
      end
    end
end

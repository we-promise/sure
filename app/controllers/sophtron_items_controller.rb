class SophtronItemsController < ApplicationController
  include SyncStats::Collector

  CONNECTION_STATUS_MAX_POLLS = 6
  LOGIN_PROGRESS_CONNECTION_STATUS_MAX_POLLS = 15
  POST_MFA_CONNECTION_STATUS_MAX_POLLS = 15
  CONNECTION_STATUS_POLL_INTERVAL_MS = 4_000
  MAX_SECURITY_ANSWERS = 10
  MAX_SECURITY_ANSWER_LENGTH = 256
  MANUAL_SYNC_PROCESSED_ACCOUNT_IDS_KEY = "manual_sync_processed_sophtron_account_ids"

  before_action :set_sophtron_item, only: [
    :show, :edit, :update, :destroy, :connect_institution, :sync,
    :connection_status, :submit_mfa, :toggle_manual_sync,
    :setup_accounts, :complete_account_setup
  ]
  before_action :require_admin!, only: [
    :new, :create, :preload_accounts, :select_accounts, :link_accounts,
    :select_existing_account, :link_existing_account, :connect_institution,
    :edit, :update, :destroy, :sync, :connection_status, :submit_mfa, :toggle_manual_sync,
    :setup_accounts, :complete_account_setup
  ]
  around_action :with_legacy_refresh, only: [ :sync, :connection_status, :submit_mfa ]
  around_action :with_legacy_credentials, only: [ :update ]
  around_action :with_legacy_discovery, only: [ :preload_accounts, :select_accounts, :select_existing_account, :setup_accounts ]
  around_action :with_legacy_lifecycle, only: [ :connect_institution, :link_accounts, :link_existing_account,
    :complete_account_setup, :toggle_manual_sync, :destroy ]

  def index
    @sophtron_items = Current.family.sophtron_items.active.ordered
    render layout: "settings"
  end

  def show
  end

  def preload_accounts
    item = configured_sophtron_item
    unless item
      render json: { success: false, error: "no_credentials_configured", has_accounts: false }
      return
    end

    item.ensure_customer!

    unless item.connected_to_institution?
      render json: { success: false, error: "no_institution_connected", has_accounts: nil }
      return
    end

    accounts = item.fetch_remote_accounts
    render json: { success: true, has_accounts: accounts.any?, cached: true }
  rescue Provider::Sophtron::Error => e
    Rails.logger.error("Sophtron preload error: #{e.message}")
    render json: { success: false, error: "api_error", error_message: t(".api_error"), has_accounts: nil }
  rescue Provider::AccountData::LegacyWriterFence::Busy, Provider::AccountData::LegacyWriterFence::OwnershipChanged, Provider::AccountData::LegacyWriterFence::InvalidSource
    raise
  rescue StandardError => e
    Rails.logger.error("Unexpected error preloading Sophtron accounts: #{e.class}: #{e.message}")
    render json: { success: false, error: "unexpected_error", error_message: t(".unexpected_error"), has_accounts: nil }
  end

  def select_accounts
    item = configured_sophtron_item
    unless item
      render_or_redirect_setup_required
      return
    end

    item.ensure_customer!

    if connect_new_institution_flow? || !item.connected_to_institution?
      prepare_connection_form(item)
      render :connect, layout: false
      return
    end

    @available_accounts = item.reject_already_linked(item.fetch_remote_accounts)
    @accountable_type = params[:accountable_type] || "Depository"
    @return_to = safe_return_to_path

    if @available_accounts.empty?
      redirect_to new_account_path, alert: t(".no_accounts_found")
      return
    end

    render_selection_form(item)
  rescue Provider::Sophtron::Error => e
    Rails.logger.error("Sophtron API error in select_accounts: #{e.message}")
    render_api_error(t(".api_error"), safe_return_to_path)
  rescue Provider::AccountData::LegacyWriterFence::Busy, Provider::AccountData::LegacyWriterFence::OwnershipChanged, Provider::AccountData::LegacyWriterFence::InvalidSource
    raise
  rescue StandardError => e
    Rails.logger.error("Unexpected error in select_accounts: #{e.class}: #{e.message}")
    render_api_error(t(".unexpected_error"), safe_return_to_path)
  end

  def connect_institution
    if params[:institution_id].blank? || params[:bank_username].blank? || params[:bank_password].blank?
      redirect_to select_accounts_sophtron_items_path(connection_context_params), alert: t(".missing_parameters")
      return
    end

    item = SophtronItem::Lifecycle.new(@sophtron_item).connect_institution(
      institution_id: params[:institution_id], institution_name: params[:institution_name],
      username: params[:bank_username], password: params[:bank_password],
      new_institution: connect_new_institution_flow?)

    redirect_to connection_status_sophtron_item_path(item, connection_context_params)
  rescue Provider::Sophtron::Error => e
    capture_lifecycle_failure(e)
    redirect_to select_accounts_sophtron_items_path(connection_context_params), alert: t(".api_error", message: e.message)
  end

  def connection_status
    if prefetch_request?
      head :no_content
      return
    end

    if @sophtron_item.current_job_id.blank?
      redirect_to select_accounts_sophtron_items_path(connection_context_params)
      return
    end

    @poll_attempt = requested_poll_attempt
    if @poll_attempt > connection_status_max_polls
      render_connection_timeout
      return
    end

    job = sophtron_response_data!(@sophtron_item.sophtron_provider.get_job_information(@sophtron_item.current_job_id))
    @sophtron_item.upsert_job_snapshot!(job)

    if Provider::Sophtron.job_success?(job)
      if manual_sync_flow?
        complete_manual_sync_from_job(job)
        return
      end

      @sophtron_item.update!(
        current_job_id: nil,
        last_connection_error: nil,
        pending_account_setup: true,
        status: :good
      )
      render_account_selection(@sophtron_item, force_refresh: true)
    elsif Provider::Sophtron.job_requires_input?(job)
      @challenge = @sophtron_item.build_mfa_challenge(job)
      prepare_connection_status_context
      render :mfa, layout: false
    elsif Provider::Sophtron.job_completed?(job)
      if manual_sync_flow?
        complete_manual_sync_from_job(job)
        return
      end

      if post_mfa_polling?
        return if render_account_selection_if_accounts_available(@sophtron_item)
      end

      render_pending_connection_status
    elsif Provider::Sophtron.job_failed?(job)
      failure_message = sophtron_connection_failure_message(job)
      @sophtron_item.update!(
        current_job_id: nil,
        current_job_sophtron_account_id: nil,
        user_institution_id: (manual_sync_flow? ? @sophtron_item.user_institution_id : nil),
        last_connection_error: failure_message,
        status: :requires_update
      )
      fail_manual_sync!(manual_sync_record, failure_message) if manual_sync_flow?
      render_institution_connection_error(failure_message)
    else
      render_pending_connection_status
    end
  rescue Provider::Sophtron::Error => e
    Rails.logger.error("Sophtron job polling error: #{e.message}")
    render_api_error(t(".api_error", message: e.message), accounts_path)
  end

  def submit_mfa
    provider = @sophtron_item.sophtron_provider
    job_id = @sophtron_item.current_job_id

    case params[:mfa_type]
    when "security_answer"
      security_answers = normalized_security_answers
      unless security_answers
        redirect_to connection_status_sophtron_item_path(@sophtron_item, connection_context_params), alert: t(".invalid_security_answers")
        return
      end

      sophtron_response_data!(provider.update_job_security_answer(job_id, security_answers))
    when "token_choice"
      sophtron_response_data!(provider.update_job_token_input(job_id, token_choice: params[:token_choice]))
    when "token_input"
      sophtron_response_data!(provider.update_job_token_input(job_id, token_input: params[:token_input]))
    when "verify_phone"
      sophtron_response_data!(provider.update_job_token_input(job_id, verify_phone_flag: true))
    when "captcha"
      sophtron_response_data!(provider.update_job_captcha(job_id, params[:captcha_input]))
    else
      redirect_to connection_status_sophtron_item_path(@sophtron_item, connection_context_params), alert: t(".unknown_challenge")
      return
    end

    redirect_to connection_status_sophtron_item_path(@sophtron_item, connection_context_params.merge(post_mfa: true))
  rescue Provider::Sophtron::Error => e
    Rails.logger.error("Sophtron MFA submission error: #{e.message}")
    redirect_to connection_status_sophtron_item_path(@sophtron_item, connection_context_params), alert: t(".api_error", message: e.message)
  end

  def link_accounts
    selected_account_ids = params[:account_ids] || []
    accountable_type = params[:accountable_type] || "Depository"
    return_to = safe_return_to_path

    if selected_account_ids.empty?
      redirect_to new_account_path, alert: t(".no_accounts_selected")
      return
    end

    item = @sophtron_item
    unless item&.connected_to_institution?
      redirect_to select_accounts_sophtron_items_path(accountable_type: accountable_type, return_to: return_to), alert: t(".no_institution_connected")
      return
    end

    result = SophtronItem::Lifecycle.new(item).link_accounts(account_ids: selected_account_ids, account_type: accountable_type)
    redirect_after_account_link(return_to, result[:created_accounts], result[:already_linked_accounts], result[:invalid_accounts])
  rescue Provider::Sophtron::Error => e
    capture_lifecycle_failure(e)
    redirect_to new_account_path, alert: t(".api_error", message: e.message)
  end

  def select_existing_account
    unless params[:account_id].present?
      redirect_to accounts_path, alert: t(".no_account_specified")
      return
    end

    @account = Current.family.accounts.find(params[:account_id])

    if @account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    item = configured_sophtron_item
    unless item
      render_or_redirect_setup_required
      return
    end

    item.ensure_customer!

    unless item.connected_to_institution?
      prepare_connection_form(item, account: @account)
      render :connect, layout: false
      return
    end

    @available_accounts = item.reject_already_linked(item.fetch_remote_accounts)
    @return_to = safe_return_to_path

    if @available_accounts.empty?
      redirect_to accounts_path, alert: t(".all_accounts_already_linked")
      return
    end

    render_selection_form(item, account: @account)
  rescue Provider::Sophtron::Error => e
    Rails.logger.error("Sophtron API error in select_existing_account: #{e.message}")
    render_api_error(t(".api_error", message: e.message), accounts_path)
  rescue Provider::AccountData::LegacyWriterFence::Busy, Provider::AccountData::LegacyWriterFence::OwnershipChanged, Provider::AccountData::LegacyWriterFence::InvalidSource
    raise
  rescue StandardError => e
    Rails.logger.error("Unexpected error in select_existing_account: #{e.class}: #{e.message}")
    render_api_error(t(".unexpected_error"), accounts_path)
  end

  def link_existing_account
    account_id = params[:account_id]
    sophtron_account_id = params[:sophtron_account_id]
    return_to = safe_return_to_path

    unless account_id.present? && sophtron_account_id.present?
      redirect_to accounts_path, alert: t(".missing_parameters")
      return
    end

    account = Current.family.accounts.find(account_id)

    if account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    item = @sophtron_item
    unless item&.connected_to_institution?
      redirect_to accounts_path, alert: t(".no_institution_connected")
      return
    end

    result = SophtronItem::Lifecycle.new(item).link_existing_account(account_id: account.id, sophtron_account_id: sophtron_account_id)
    if result[:error]
      redirect_to accounts_path, alert: t(".#{result[:error]}")
      return
    end
    redirect_to return_to || accounts_path, notice: t(".success", account_name: result[:account].name)
  rescue Provider::Sophtron::Error => e
    capture_lifecycle_failure(e)
    redirect_to accounts_path, alert: t(".api_error", message: e.message)
  end

  def new
    @sophtron_item = Current.family.sophtron_items.build
  end

  def create
    @sophtron_item = Current.family.sophtron_items.build(sophtron_params)
    @sophtron_item.name ||= t("sophtron_items.defaults.name")

    if @sophtron_item.save
      unless verify_and_provision_customer(@sophtron_item)
        render_sophtron_panel_error(:new, @sophtron_item.last_connection_error)
        return
      end

      render_sophtron_panel_success(:create)
    else
      render_sophtron_panel_error(:new, @sophtron_item.errors.full_messages.join(", "))
    end
  end

  def edit
  end

  def update
    if @sophtron_item.update(sophtron_params)
      unless verify_and_provision_customer(@sophtron_item)
        render_sophtron_panel_error(:edit, @sophtron_item.last_connection_error)
        return
      end

      render_sophtron_panel_success(:update)
    else
      render_sophtron_panel_error(:edit, @sophtron_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    results = SophtronItem::Lifecycle.new(@sophtron_item).disconnect
    if results.any? { |result| result[:error].present? }
      redirect_to accounts_path, alert: t("sophtron_items.connection_unavailable")
      return
    end
    redirect_to accounts_path, notice: t(".success")
  end

  def sync
    if @sophtron_item.manual_sync_required?
      start_manual_sync
      return
    end

    @sophtron_item.sync_later unless @sophtron_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def toggle_manual_sync
    result = SophtronItem::Lifecycle.new(@sophtron_item).toggle_manual_sync(
      institution_key: params[:institution_key].presence || params[:user_institution_id])
    if result[:error]
      redirect_back_or_to accounts_path, alert: t("sophtron_items.sync.no_linked_accounts")
      return
    end
    enabled = result[:enabled]

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path, notice: t(".success_#{enabled ? 'enabled' : 'disabled'}") }
      format.turbo_stream do
        flash.now[:notice] = t(".success_#{enabled ? 'enabled' : 'disabled'}")
        render turbo_stream: [
          turbo_stream.replace(
            ActionView::RecordIdentifier.dom_id(@sophtron_item),
            partial: "sophtron_items/sophtron_item",
            locals: { sophtron_item: @sophtron_item.reload }
          ),
          *flash_notification_stream_items
        ]
      end
    end
  end

  def setup_accounts
    @api_error = fetch_sophtron_accounts_from_api
    @selection_token = SophtronItem::Selection.issue(@sophtron_item, flow: :complete_account_setup)

    @sophtron_accounts = @sophtron_item.sophtron_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })

    supported_types = Provider::SophtronAdapter.supported_account_types
    account_type_keys = {
      "depository" => "Depository",
      "credit_card" => "CreditCard",
      "investment" => "Investment",
      "loan" => "Loan",
      "other_asset" => "OtherAsset"
    }

    all_account_type_options = account_type_keys.filter_map do |key, type|
      next unless supported_types.include?(type)
      [ t(".account_types.#{key}"), type ]
    end

    @account_type_options = [ [ t(".account_types.skip"), "skip" ] ] + all_account_type_options
    @subtype_options = {
      "Depository" => {
        label: "Account Subtype:",
        options: Depository::SUBTYPES.map { |k, v| [ v[:long], k ] }
      },
      "CreditCard" => {
        label: "",
        options: [],
        message: "Credit cards will be automatically set up as credit card accounts."
      },
      "Investment" => {
        label: "Investment Type:",
        options: Investment::SUBTYPES.map { |k, v| [ v[:long], k ] }
      },
      "Loan" => {
        label: "Loan Type:",
        options: Loan::SUBTYPES.map { |k, v| [ v[:long], k ] }
      },
      "Crypto" => {
        label: nil,
        options: [],
        message: "Crypto accounts track cryptocurrency holdings."
      },
      "OtherAsset" => {
        label: nil,
        options: [],
        message: "No additional options needed for Other Assets."
      }
    }
  end

  def complete_account_setup
    account_types = params[:account_types] || {}
    account_subtypes = params[:account_subtypes] || {}

    begin
      result = SophtronItem::Lifecycle.new(@sophtron_item).complete_account_setup(
        account_types: account_types, account_subtypes: account_subtypes)
      created_accounts, skipped_count = result.values_at(:created_accounts, :skipped_count)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      capture_lifecycle_failure(e)
      flash[:alert] = t(".creation_failed")
      redirect_to accounts_path, status: :see_other
      return
    rescue Provider::AccountData::LegacyWriterFence::Busy, Provider::AccountData::LegacyWriterFence::OwnershipChanged, Provider::AccountData::LegacyWriterFence::InvalidSource
      raise
    rescue StandardError => e
      capture_lifecycle_failure(e)
      flash[:alert] = t(".unexpected_error")
      redirect_to accounts_path, status: :see_other
      return
    end

    flash[:notice] = if created_accounts.any?
      t(".success", count: created_accounts.count)
    elsif skipped_count > 0
      t(".all_skipped")
    else
      t(".no_accounts")
    end

    if turbo_frame_request?
      @manual_accounts = Account.uncached {
        Current.family.accounts.visible_manual.order(:name).to_a
      }
      @sophtron_items = Current.family.sophtron_items.ordered
      manual_accounts_stream = if @manual_accounts.any?
        turbo_stream.update(
          "manual-accounts",
          partial: "accounts/index/manual_accounts",
          locals: { accounts: @manual_accounts }
        )
      else
        turbo_stream.replace("manual-accounts", view_context.tag.div(id: "manual-accounts"))
      end

      render turbo_stream: [
        manual_accounts_stream,
        turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(@sophtron_item),
          partial: "sophtron_items/sophtron_item",
          locals: { sophtron_item: @sophtron_item }
        )
      ] + Array(flash_notification_stream_items)
    else
      redirect_to accounts_path, status: :see_other
    end
  end

  private

    def start_manual_sync
      if @sophtron_item.current_job_sophtron_account_id.present?
        redirect_to active_manual_sync_path, alert: t(".already_running")
        return
      end

      unless linked_manual_sync_sophtron_accounts.exists?
        redirect_back_or_to accounts_path, alert: t(".no_linked_accounts")
        return
      end

      sync = @sophtron_item.syncs.create!
      sync.start! if sync.may_start?
      @manual_sync = sync

      provider = @sophtron_item.sophtron_provider
      raise Provider::Sophtron::Error.new("Sophtron provider is not configured", :configuration_error) unless provider

      reset_manual_sync_progress!(sync)
      start_next_manual_sync_account(sync, provider)
    rescue Provider::Sophtron::Error => e
      clear_or_fail_manual_sync_after_error!(sync, e.message) if defined?(sync) && sync.present?
      Rails.logger.error("Sophtron manual sync error: #{e.message}")
      redirect_back_or_to accounts_path, alert: t(".api_error", message: e.message)
    end

    def active_manual_sync_path
      return accounts_path if @sophtron_item.current_job_id.blank?

      connection_status_sophtron_item_path(
        @sophtron_item,
        connection_context_params.merge(
          manual_sync: true,
          sync_id: manual_sync_record&.id,
          sophtron_account_id: @sophtron_item.current_job_sophtron_account_id
        )
      )
    end

    def start_next_manual_sync_account(sync, provider)
      sophtron_account = next_manual_sync_sophtron_account(sync)

      unless sophtron_account
        @sophtron_item.update!(
          current_job_id: nil,
          current_job_sophtron_account_id: nil,
          last_connection_error: nil,
          status: :good
        )
        sync.finalize_if_all_children_finalized
        flash.discard(:alert)
        @manual_sync = sync
        render :manual_sync_complete, layout: false
        return
      end

      start_manual_sync_for_account(sophtron_account, provider, sync)
    end

    def start_manual_sync_for_account(sophtron_account, provider, sync)
      refresh_response = sophtron_response_data!(provider.refresh_account(sophtron_account.account_id)).with_indifferent_access
      job_id = refresh_response[:JobID] || refresh_response[:job_id]

      if job_id.blank?
        complete_manual_sync!(sophtron_account, provider, sync)
        start_next_manual_sync_account(sync, provider)
        return
      end

      @sophtron_item.update!(
        current_job_id: job_id,
        current_job_sophtron_account_id: sophtron_account.id,
        raw_job_payload: refresh_response,
        job_status: nil,
        last_connection_error: nil,
        status: :good
      )

      job = sophtron_response_data!(provider.get_job_information(job_id))
      @sophtron_item.upsert_job_snapshot!(job)

      if Provider::Sophtron.job_requires_input?(job)
        @challenge = @sophtron_item.build_mfa_challenge(job)
        prepare_connection_status_context
        render :mfa, layout: false
      elsif Provider::Sophtron.job_failed?(job)
        failure_message = t(".failed")
        fail_manual_sync_and_clear_job!(sync, failure_message)
        redirect_back_or_to accounts_path, alert: failure_message
      elsif Provider::Sophtron.job_success?(job) || Provider::Sophtron.job_completed?(job)
        complete_manual_sync!(sophtron_account, provider, sync)
        start_next_manual_sync_account(sync, provider)
      else
        @poll_attempt = 1
        render_pending_connection_status
      end
    end

    def complete_manual_sync_from_job(job)
      sophtron_account = @sophtron_item.current_job_sophtron_account
      sophtron_account ||= linked_manual_sync_sophtron_accounts.find_by(id: params[:sophtron_account_id]) if params[:sophtron_account_id].present?
      sync = manual_sync_record

      unless sophtron_account && sync
        @sophtron_item.update!(current_job_id: nil, current_job_sophtron_account_id: nil)
        render_api_error(t("sophtron_items.sync.no_linked_accounts"), accounts_path)
        return
      end

      provider = @sophtron_item.sophtron_provider
      complete_manual_sync!(sophtron_account, provider, sync)
      start_next_manual_sync_account(sync, provider)
    rescue Provider::Sophtron::Error => e
      fail_manual_sync_and_clear_job!(sync, e.message) if defined?(sync) && sync.present?
      render_api_error(t("sophtron_items.sync.api_error", message: e.message), accounts_path)
    end

    def complete_manual_sync!(sophtron_account, provider, sync)
      raise Provider::Sophtron::Error.new("Sophtron provider is not configured", :configuration_error) unless provider

      result = SophtronItem::Importer.new(@sophtron_item, sync: sync)
                                    .import_transactions_after_refresh(sophtron_account)

      unless result[:success]
        error_message = result[:error] || t("sophtron_items.sync.failed")
        fail_manual_sync_and_clear_job!(sync, error_message)
        raise Provider::Sophtron::Error.new(error_message, :api_error)
      end

      processing_result = process_manual_sync_account!(sync, sophtron_account)
      mark_manual_sync_account_processed!(sync, sophtron_account)
      collect_manual_sync_stats!(sync, processing_result)
      @sophtron_item.update!(
        current_job_id: nil,
        current_job_sophtron_account_id: nil,
        last_connection_error: nil,
        status: :good
      )

      sophtron_account = Provider::AccountData::LegacyWriterFence.scoped_accounts!(@sophtron_item, [ sophtron_account ]).sole
      if sophtron_account.current_account
        @sophtron_item.schedule_account_syncs(
          sophtron_accounts_scope: [ sophtron_account ],
          parent_sync: sync,
          window_start_date: sync.window_start_date,
          window_end_date: sync.window_end_date
        )
      else
        sync.finalize_if_all_children_finalized
      end

      @manual_sync_account = sophtron_account
      @manual_sync = sync
    end

    def process_manual_sync_account!(sync, sophtron_account)
      SophtronAccount::Processor.new(sophtron_account, sync: sync).process
    rescue Provider::AccountData::LegacyWriterFence::Busy, Provider::AccountData::LegacyWriterFence::OwnershipChanged, Provider::AccountData::LegacyWriterFence::InvalidSource
      raise
    rescue StandardError => e
      Rails.logger.error("Sophtron manual sync processing error: #{e.class} - #{e.message}")
      fail_manual_sync_and_clear_job!(sync, e.message)
      raise Provider::Sophtron::Error.new(t("sophtron_items.sync.processing_failed"), :api_error)
    end

    def fail_manual_sync_and_clear_job!(sync, message)
      clear_manual_sync_job!(message, status: :requires_update)
      fail_manual_sync!(sync, message)
    end

    def clear_or_fail_manual_sync_after_error!(sync, message)
      if sync.failed?
        clear_manual_sync_job!(@sophtron_item.last_connection_error, status: :requires_update)
      else
        fail_manual_sync_and_clear_job!(sync, message)
      end
    end

    def clear_manual_sync_job!(message = nil, status: nil)
      attributes = {
        current_job_id: nil,
        current_job_sophtron_account_id: nil
      }
      attributes[:last_connection_error] = message if message.present?
      attributes[:status] = status if status.present?

      @sophtron_item.update!(attributes)
    end

    def fail_manual_sync!(sync, message)
      return unless sync

      sync.start! if sync.may_start?
      sync.fail! if sync.may_fail?
      sync.update!(error: message)
    end

    def manual_sync_record
      return @manual_sync if defined?(@manual_sync) && @manual_sync.present?

      sync = @sophtron_item.syncs.find_by(id: params[:sync_id]) if params[:sync_id].present?
      sync || visible_manual_sync_record
    end

    def visible_manual_sync_record
      @sophtron_item.syncs.visible.ordered.detect do |sync|
        sync.sync_stats.to_h.key?(MANUAL_SYNC_PROCESSED_ACCOUNT_IDS_KEY)
      end
    end

    def linked_manual_sync_sophtron_accounts
      @sophtron_item.manual_sync_sophtron_accounts
    end

    def next_manual_sync_sophtron_account(sync)
      processed_ids = manual_sync_processed_sophtron_account_ids(sync)
      linked_manual_sync_sophtron_accounts.detect { |sophtron_account| processed_ids.exclude?(sophtron_account.id.to_s) }
    end

    def reset_manual_sync_progress!(sync)
      sync.update!(sync_stats: { MANUAL_SYNC_PROCESSED_ACCOUNT_IDS_KEY => [] })
    end

    def mark_manual_sync_account_processed!(sync, sophtron_account)
      processed_ids = manual_sync_processed_sophtron_account_ids(sync)
      processed_ids << sophtron_account.id.to_s
      stats = sync.sync_stats.to_h
      sync.update!(sync_stats: stats.merge(MANUAL_SYNC_PROCESSED_ACCOUNT_IDS_KEY => processed_ids.uniq))
    end

    def collect_manual_sync_stats!(sync, processing_result)
      mark_import_started(sync)
      collect_setup_stats(sync, provider_accounts: @sophtron_item.sophtron_accounts.includes(:account_provider, :account))

      account_ids = @sophtron_item.sophtron_accounts
                                  .where(id: manual_sync_processed_sophtron_account_ids(sync))
                                  .includes(:account_provider)
                                  .filter_map { |sophtron_account| sophtron_account.current_account&.id }

      collect_transaction_stats(
        sync,
        account_ids: account_ids,
        source: "sophtron",
        window_start: sync.syncing_at || sync.created_at,
        window_end: Time.current
      )

      collect_manual_sync_health_stats!(sync, processing_result)
    end

    def collect_manual_sync_health_stats!(sync, processing_result)
      if processing_result.is_a?(Hash) && processing_result[:success] == false
        errors = Array(processing_result[:errors]).presence || [ { message: t("sophtron_items.sync.failed"), category: "transaction_import" } ]
        collect_health_stats(sync, errors: errors)
      elsif sync.sync_stats.to_h["total_errors"].to_i.zero?
        collect_health_stats(sync, errors: nil)
      end
    end

    def manual_sync_processed_sophtron_account_ids(sync)
      Array(sync.sync_stats.to_h[MANUAL_SYNC_PROCESSED_ACCOUNT_IDS_KEY]).map(&:to_s)
    end

    def configured_sophtron_item
      @legacy_discovery_item || Current.family.configured_sophtron_item
    end

    def normalized_security_answers
      raw_answers = Array(params[:security_answers]).flatten
      return if raw_answers.size > MAX_SECURITY_ANSWERS
      return if raw_answers.any? { |answer| answer.to_s.length > MAX_SECURITY_ANSWER_LENGTH }

      answers = raw_answers.filter_map do |answer|
        answer.to_s.strip.presence
      end

      return if answers.empty?

      answers
    end

    def sophtron_response_data!(response)
      Provider::Sophtron.response_data!(response)
    end

    def verify_and_provision_customer(item)
      item.verify_and_provision_customer
    end

    def render_sophtron_panel_success(action_name)
      if turbo_frame_request?
        flash.now[:notice] = t("sophtron_items.#{action_name}.success")
        @sophtron_items = Current.family.sophtron_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "sophtron-providers-panel",
            partial: "settings/providers/sophtron_panel",
            locals: { sophtron_items: @sophtron_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to accounts_path, notice: t("sophtron_items.#{action_name}.success"), status: :see_other
      end
    end

    def render_sophtron_panel_error(view_name, message)
      @error_message = message
      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "sophtron-providers-panel",
          partial: "settings/providers/sophtron_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        render view_name, status: :unprocessable_entity
      end
    end

    def render_or_redirect_setup_required
      if turbo_frame_request?
        render partial: "sophtron_items/setup_required", layout: false
      else
        redirect_to settings_providers_path, alert: t("sophtron_items.select_accounts.no_credentials_configured")
      end
    end

    def prepare_connection_form(item, account: nil)
      @sophtron_item = item
      @account = account
      @accountable_type = params[:accountable_type] || "Depository"
      @return_to = safe_return_to_path
      @connect_new_institution = connect_new_institution_flow?
      @institution_search = params[:institution_name].to_s.strip
      @institutions = []

      if @institution_search.length >= 2
        @institutions = item.search_institutions(@institution_search)
      end
    end

    def render_account_selection(item, force_refresh: false)
      @available_accounts = item.reject_already_linked(item.fetch_remote_accounts(force: force_refresh))
      @accountable_type = params[:accountable_type] || "Depository"
      @return_to = safe_return_to_path

      account = Current.family.accounts.find(params[:account_id]) if params[:account_id].present?
      render_selection_form(item, account: account)
    end

    def render_account_selection_if_accounts_available(item)
      accounts = item.fetch_remote_accounts(force: true)
      return false if accounts.empty?

      item.update!(
        current_job_id: nil,
        last_connection_error: nil,
        pending_account_setup: true,
        status: :good
      )

      @available_accounts = item.reject_already_linked(accounts)
      @accountable_type = params[:accountable_type] || "Depository"
      @return_to = safe_return_to_path

      account = Current.family.accounts.find(params[:account_id]) if params[:account_id].present?
      render_selection_form(item, account: account)

      true
    rescue Provider::Sophtron::Error => e
      Rails.logger.info("Sophtron accounts are not available after completed job #{item.current_job_id}: #{e.message}")
      false
    end

    def render_selection_form(item, account: nil)
      @account = account
      flow = account ? :link_existing_account : :link_accounts
      @selection_token = SophtronItem::Selection.issue(item, flow: flow, account_id: account&.id)
      render(account ? :select_existing_account : :select_accounts, layout: false)
    end

    def render_pending_connection_status
      if @poll_attempt >= connection_status_max_polls
        render_connection_timeout
        return
      end

      prepare_connection_status_context
      @next_poll_attempt = @poll_attempt + 1
      render :connection_status, layout: false
    end

    def prepare_connection_status_context
      @accountable_type = params[:accountable_type] || "Depository"
      @account_id = params[:account_id]
      @return_to = safe_return_to_path
      @manual_sync_flow = manual_sync_flow?
      @manual_sync_id = manual_sync_record&.id if @manual_sync_flow
      @manual_sync_sophtron_account_id = params[:sophtron_account_id] || @sophtron_item.current_job_sophtron_account_id
      @poll_interval_ms = CONNECTION_STATUS_POLL_INTERVAL_MS
      @post_mfa_polling = post_mfa_polling?
      @max_poll_attempts = connection_status_max_polls
    end

    def requested_poll_attempt
      poll_attempt = params[:poll_attempt].to_i
      poll_attempt.positive? ? poll_attempt : 1
    end

    def render_connection_timeout
      @poll_attempt = connection_status_max_polls if @poll_attempt.to_i > connection_status_max_polls
      @poll_attempt = 1 if @poll_attempt.to_i < 1
      @sophtron_item.update!(
        last_connection_error: t(".timeout"),
        status: :requires_update
      )
      prepare_connection_status_context
      @timed_out = true
      render :connection_status, layout: false
    end

    def connection_status_max_polls
      if post_mfa_polling?
        POST_MFA_CONNECTION_STATUS_MAX_POLLS
      elsif login_progress_polling?
        LOGIN_PROGRESS_CONNECTION_STATUS_MAX_POLLS
      else
        CONNECTION_STATUS_MAX_POLLS
      end
    end

    def post_mfa_polling?
      ActiveModel::Type::Boolean.new.cast(params[:post_mfa]) || post_mfa_job_payload?(@sophtron_item.raw_job_payload)
    end

    def manual_sync_flow?
      ActiveModel::Type::Boolean.new.cast(params[:manual_sync]) || @sophtron_item.current_job_sophtron_account_id.present?
    end

    def post_mfa_job_payload?(job_payload)
      job = (job_payload || {}).with_indifferent_access
      job[:TokenInput].present? || %w[TokenInput TransactionTable].include?(job[:LastStep].to_s)
    end

    def login_progress_polling?
      login_progress_job_payload?(@sophtron_item.raw_job_payload)
    end

    def login_progress_job_payload?(job_payload)
      job = (job_payload || {}).with_indifferent_access
      last_status = job[:LastStatus] || job[:last_status]
      return false if Provider::Sophtron.failure_job_status?(last_status)

      job[:LastStep].present? || job[:last_step].present? || last_status.present?
    end

    def prefetch_request?
      [
        request.headers["X-Sec-Purpose"],
        request.headers["Sec-Purpose"],
        request.headers["Purpose"]
      ].any? { |value| value.to_s.include?("prefetch") }
    end

    def render_institution_connection_error(message)
      render_api_error(
        message,
        select_accounts_sophtron_items_path(connection_context_params.except(:post_mfa, "post_mfa")),
        heading: t("sophtron_items.api_error.institution_unable_to_connect"),
        issue_keys: %w[bad_credentials verification_code institution_timeout unsupported_mfa],
        action_label: t("sophtron_items.api_error.try_again")
      )
    end

    def sophtron_connection_failure_message(job)
      last_status = job.with_indifferent_access[:LastStatus].to_s
      return t("sophtron_items.connection_status.failed_timeout") if last_status.match?(/timeout/i)

      t("sophtron_items.connection_status.failed")
    end

    def render_api_error(message, return_path, heading: nil, issue_keys: nil, action_label: nil)
      render partial: "sophtron_items/api_error",
             locals: {
               error_message: message,
               return_path: return_path,
               heading: heading,
               issue_keys: issue_keys,
               action_label: action_label
             },
             layout: false
    end

    def redirect_after_account_link(return_to, created_accounts, already_linked_accounts, invalid_accounts)
      if invalid_accounts.any? && created_accounts.empty? && already_linked_accounts.empty?
        redirect_to new_account_path, alert: t(".invalid_account_names", count: invalid_accounts.count)
      elsif invalid_accounts.any? && (created_accounts.any? || already_linked_accounts.any?)
        redirect_to return_to || accounts_path,
                    alert: t(".partial_invalid",
                             created_count: created_accounts.count,
                             already_linked_count: already_linked_accounts.count,
                             invalid_count: invalid_accounts.count)
      elsif created_accounts.any? && already_linked_accounts.any?
        redirect_to return_to || accounts_path,
                    notice: t(".partial_success",
                             created_count: created_accounts.count,
                             already_linked_count: already_linked_accounts.count,
                             already_linked_names: already_linked_accounts.join(", "))
      elsif created_accounts.any?
        redirect_to return_to || accounts_path, notice: t(".success", count: created_accounts.count)
      elsif already_linked_accounts.any?
        redirect_to return_to || accounts_path,
                    alert: t(".all_already_linked",
                            count: already_linked_accounts.count,
                            names: already_linked_accounts.join(", "))
      else
        redirect_to new_account_path, alert: t(".link_failed")
      end
    end

    def fetch_sophtron_accounts_from_api
      return nil unless @sophtron_item.sophtron_accounts.empty?
      return t("sophtron_items.setup_accounts.no_access_key") unless @sophtron_item.credentials_configured?
      return t("sophtron_items.setup_accounts.no_institution_connected") unless @sophtron_item.connected_to_institution?

      @sophtron_item.fetch_remote_accounts(force: true)
      nil
    rescue Provider::Sophtron::Error => e
      Rails.logger.error("Sophtron API error: #{e.message}")
      t("sophtron_items.setup_accounts.api_error")
    rescue Provider::AccountData::LegacyWriterFence::Busy, Provider::AccountData::LegacyWriterFence::OwnershipChanged, Provider::AccountData::LegacyWriterFence::InvalidSource
      raise
    rescue StandardError => e
      Rails.logger.error("Unexpected error fetching Sophtron accounts: #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(10).join("\n"))
      t("sophtron_items.setup_accounts.api_error")
    end

    def set_sophtron_item
      @sophtron_item = Current.family.sophtron_items.find(params[:id])
    end

    def with_legacy_refresh
      with_legacy_operation(@sophtron_item, operation: :sync) { yield }
    end

    def with_legacy_credentials
      with_legacy_operation(@sophtron_item, operation: :credentials) { yield }
    end

    def with_legacy_discovery
      item = @sophtron_item || configured_sophtron_item
      return yield unless item

      with_legacy_operation(item, operation: :ingest) do
        @legacy_discovery_item = @sophtron_item
        yield
      end
    ensure
      @legacy_discovery_item = nil
    end

    def with_legacy_lifecycle
      if SophtronItem::Selection::FLOWS.include?(action_name)
        selection = SophtronItem::Selection.from_token(params[:selection_token], flow: action_name,
          account_id: action_name == "link_existing_account" ? params[:account_id] : nil)
        item = selection.item_for(Current.family)
        if @sophtron_item && @sophtron_item.id != item.id
          raise SophtronItem::Selection::Invalid, "Sophtron setup selection identifies another item"
        end
      else
        item = @sophtron_item
      end
      return yield unless item

      with_legacy_operation(item, operation: :lifecycle) do
        selection&.verify!(@sophtron_item)
        @legacy_discovery_item = @sophtron_item
        yield
      end
    rescue SophtronItem::Selection::Invalid => error
      render_legacy_operation_denial(@sophtron_item, error)
    ensure
      @legacy_discovery_item = nil
    end

    def with_legacy_operation(item, operation:)
      Provider::AccountData::LegacyWriterFence.with_item(item, operation: operation) do |current|
        @sophtron_item = current
        yield
      end
    rescue Provider::AccountData::LegacyWriterFence::Busy, Provider::AccountData::LegacyWriterFence::OwnershipChanged => error
      render_legacy_operation_denial(item, error)
    end

    def render_legacy_operation_denial(item, error)
      DebugLogEntry.capture(category: "provider_sync_error", level: "warn",
        message: "Sophtron operation was refused by migration ownership", source: self.class.name,
        provider_key: "sophtron", family: Current.family,
        metadata: { item_id: item&.id, error_class: error.class.name })
      message = t("sophtron_items.connection_unavailable")
      respond_to do |format|
        format.json { render json: { error: message }, status: :conflict }
        format.html { redirect_to accounts_path, alert: message }
      end
    end

    def capture_lifecycle_failure(error)
      DebugLogEntry.capture(category: "provider_sync_error", level: "warn",
        message: "Sophtron lifecycle operation failed", source: self.class.name,
        provider_key: "sophtron", family: Current.family,
        metadata: { item_id: @sophtron_item&.id, operation: action_name, error_class: error.class.name })
    rescue StandardError
      # Keep the existing user-facing failure response if diagnostics are down.
    end

    def sophtron_params
      params.require(:sophtron_item).permit(:name, :user_id, :access_key, :base_url, :sync_start_date)
    end

    def connection_context_params
      params.permit(:accountable_type, :account_id, :return_to, :post_mfa, :connect_new_institution, :manual_sync, :sync_id, :sophtron_account_id, :institution_key, :user_institution_id).to_h.compact
    end

    def connect_new_institution_flow?
      ActiveModel::Type::Boolean.new.cast(params[:connect_new_institution])
    end

    def safe_return_to_path
      return nil if params[:return_to].blank?

      return_to = params[:return_to].to_s

      begin
        uri = URI.parse(return_to)
        return nil if uri.scheme.present? || uri.host.present?
        return nil if return_to.start_with?("//")
        return nil unless return_to.start_with?("/")

        return_to
      rescue URI::InvalidURIError
        nil
      end
    end
end

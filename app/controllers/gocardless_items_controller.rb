# frozen_string_literal: true

class GocardlessItemsController < ApplicationController
  before_action :require_admin!

  ALLOWED_ACCOUNTABLE_TYPES = %w[Depository CreditCard Investment Loan OtherAsset OtherLiability Crypto Property Vehicle].freeze

  before_action :set_gocardless_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  # GoCardless sends the user's browser back here after they consent at their bank. It
  # carries no session, so the item is recovered from the `ref` we set when creating the
  # requisition. `ref` is the item's own uuid, and the lookup is scoped to the current
  # family, so a guessed or replayed value cannot reach another family's item.
  def callback
    item = Current.family.gocardless_items.find_by(id: params[:ref])

    if item.nil?
      redirect_to accounts_path, alert: t(".unknown_connection", default: "That bank connection could not be found."), status: :see_other
      return
    end

    provider = Provider::GocardlessAdapter.build_provider(family: Current.family)
    requisition = provider.get_requisition(requisition_id: item.requisition_id)
    item.update(requisition_status: requisition[:status])

    # LN (linked) is the only status where accounts are readable. Anything else means the
    # user abandoned or the bank rejected the consent, and retrying the same requisition
    # will not help: a fresh one is needed.
    if requisition[:status].to_s == "LN"
      item.update(pending_account_setup: true)

      # Consent alone creates no local records: the accounts still have to be fetched
      # from the requisition. Without this the setup screen renders an empty list,
      # because there is nothing to show until the importer has run.
      item.sync_later

      redirect_to accounts_path,
                  notice: t(".success", default: "Connected to #{item.institution_name || 'your bank'}. Your accounts are being synced."),
                  status: :see_other
    else
      redirect_to accounts_path,
                  alert: t(".not_linked", default: "The bank did not complete the connection (status #{requisition[:status]}). Please try connecting again."),
                  status: :see_other
    end
  rescue Provider::Gocardless::GocardlessError => e
    Rails.logger.error "GocardlessItemsController#callback - #{e.message}"
    redirect_to accounts_path, alert: e.message, status: :see_other
  end

  # Creates the consent and hands the user to their bank.
  #
  # The item is created HERE rather than before bank selection. GoCardless credentials
  # are account-level, so an item is really "one bank connection", and there is nothing
  # meaningful to persist until a bank has been chosen. Creating it earlier would also
  # mean a GET request creating records, which a prefetch or crawler could trigger.
  def connect
    institution_id = params[:institution_id]
    provider = Provider::GocardlessAdapter.build_provider(family: Current.family)

    if provider.nil?
      redirect_to settings_providers_path, alert: t(".not_configured", default: "Add your GoCardless credentials first."), status: :see_other
      return
    end

    @gocardless_item = connection_item_for_new_bank

    if @gocardless_item.nil?
      redirect_to settings_providers_path, alert: t(".not_configured", default: "Add your GoCardless credentials first."), status: :see_other
      return
    end

    institution = provider.get_institution(institution_id: institution_id)

    # Ask for as much history and as long an access window as this institution allows,
    # rather than the API defaults. UK banks commonly offer 730 days of history but
    # default to far less, and re-consenting is user-visible friction worth avoiding.
    agreement = provider.create_agreement(
      institution_id: institution_id,
      max_historical_days: institution[:transaction_total_days].presence&.to_i ||
                           Provider::Gocardless::DEFAULT_MAX_HISTORICAL_DAYS,
      access_valid_for_days: institution[:max_access_valid_for_days].presence&.to_i ||
                             Provider::Gocardless::DEFAULT_ACCESS_VALID_FOR_DAYS
    )

    requisition = provider.create_requisition(
      institution_id: institution_id,
      redirect: callback_gocardless_items_url,
      reference: @gocardless_item.id,
      agreement: agreement[:id],
      user_language: "EN"
    )

    @gocardless_item.update!(
      institution_id: institution_id,
      institution_name: institution[:name],
      institution_url: institution[:logo],
      agreement_id: agreement[:id],
      requisition_id: requisition[:id],
      requisition_status: requisition[:status]
    )

    safe_redirect_to_gocardless(
      requisition[:link],
      fallback_path: new_gocardless_item_path,
      fallback_alert: t(".invalid_redirect", default: "The bank connection returned an unexpected address, so it was not followed.")
    )
  rescue Provider::Gocardless::GocardlessError => e
    Rails.logger.error "GocardlessItemsController#connect - #{e.message}"
    redirect_to new_gocardless_item_path, alert: e.message, status: :see_other
  end

  def index
    @gocardless_items = Current.family.gocardless_items.ordered
  end

  def show
  end

  # Bank picker. Institutions are scoped to a country by the API, so the country select
  # reloads the list rather than filtering client-side.
  def new
    @country = params[:country].presence || "GB"
    provider = Provider::GocardlessAdapter.build_provider(family: Current.family)

    if provider.nil?
      redirect_to settings_providers_path,
                  alert: t(".not_configured", default: "Add your GoCardless credentials first."),
                  status: :see_other
      return
    end

    @institutions = provider.get_institutions(country: @country).sort_by { |i| i[:name].to_s }
  rescue Provider::Gocardless::GocardlessError => e
    @institutions = []
    @error_message = e.message
  end

  def edit
  end

  def create
    @gocardless_item = Current.family.gocardless_items.build(gocardless_item_params)
    @gocardless_item.name ||= "Gocardless Connection"

    if @gocardless_item.save
      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully configured Gocardless.")
        @gocardless_items = Current.family.gocardless_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "gocardless-providers-panel",
            partial: "settings/providers/gocardless_panel",
            locals: { gocardless_items: @gocardless_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @gocardless_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "gocardless-providers-panel",
          partial: "settings/providers/gocardless_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def update
    if @gocardless_item.update(gocardless_item_params)
      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully updated Gocardless configuration.")
        @gocardless_items = Current.family.gocardless_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "gocardless-providers-panel",
            partial: "settings/providers/gocardless_panel",
            locals: { gocardless_items: @gocardless_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @gocardless_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "gocardless-providers-panel",
          partial: "settings/providers/gocardless_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def destroy
    @gocardless_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success", default: "Scheduled Gocardless connection for deletion.")
  end

  def sync
    unless @gocardless_item.syncing?
      @gocardless_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Collection actions for account linking flow

  def preload_accounts
    # Trigger a sync to fetch accounts from the provider
    gocardless_item = Current.family.gocardless_items.first
    unless gocardless_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    gocardless_item.sync_later unless gocardless_item.syncing?
    redirect_to select_accounts_gocardless_items_path(accountable_type: params[:accountable_type], return_to: params[:return_to])
  end

  def select_accounts
    @accountable_type = params[:accountable_type]
    @return_to = params[:return_to]

    gocardless_item = Current.family.gocardless_items.first
    unless gocardless_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @gocardless_accounts = gocardless_item.gocardless_accounts
                                                .left_joins(:account_provider)
                                                .where(account_providers: { id: nil })
                                                .order(:name)
  end

  def link_accounts
    gocardless_item = Current.family.gocardless_items.first
    unless gocardless_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_api_key")
      return
    end

    selected_ids = params[:selected_account_ids] || []
    if selected_ids.empty?
      redirect_to select_accounts_gocardless_items_path, alert: t(".no_accounts_selected")
      return
    end

    accountable_type = params[:accountable_type] || "Depository"
    created_count = 0
    already_linked_count = 0
    invalid_count = 0

    gocardless_item.gocardless_accounts.where(id: selected_ids).find_each do |gocardless_account|
      # Skip if already linked
      if gocardless_account.account_provider.present?
        already_linked_count += 1
        next
      end

      # Skip if invalid name
      if gocardless_account.name.blank?
        invalid_count += 1
        next
      end

      # Create Sure account and link
      link_gocardless_account(gocardless_account, accountable_type)
      created_count += 1
    rescue => e
      Rails.logger.error "GocardlessItemsController#link_accounts - Failed to link account: #{e.message}"
    end

    if created_count > 0
      gocardless_item.sync_later unless gocardless_item.syncing?
      redirect_to accounts_path, notice: t(".success", count: created_count)
    else
      redirect_to select_accounts_gocardless_items_path, alert: t(".link_failed")
    end
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    @gocardless_item = Current.family.gocardless_items.first

    unless @gocardless_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @gocardless_accounts = @gocardless_item.gocardless_accounts
                                                      .left_joins(:account_provider)
                                                      .where(account_providers: { id: nil })
                                                      .order(:name)
  end

  def link_existing_account
    account = Current.family.accounts.find(params[:account_id])
    gocardless_item = Current.family.gocardless_items.first

    unless gocardless_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_api_key")
      return
    end

    gocardless_account = gocardless_item.gocardless_accounts.find(params[:gocardless_account_id])

    if gocardless_account.account_provider.present?
      redirect_to account_path(account), alert: t(".provider_account_already_linked")
      return
    end

    gocardless_account.ensure_account_provider!(account)
    gocardless_item.sync_later unless gocardless_item.syncing?

    redirect_to account_path(account), notice: t(".success", account_name: account.name)
  end

  def setup_accounts
    @unlinked_accounts = @gocardless_item.unlinked_gocardless_accounts.order(:name)

    if @unlinked_accounts.empty?
      redirect_to accounts_path, notice: t(".all_accounts_linked")
    end
  end

  def complete_account_setup
    account_configs = params[:accounts] || {}

    if account_configs.empty?
      redirect_to setup_accounts_gocardless_item_path(@gocardless_item), alert: t(".no_accounts")
      return
    end

    created_count = 0
    skipped_count = 0

    account_configs.each do |gocardless_account_id, config|
      next if config[:account_type] == "skip"

      gocardless_account = @gocardless_item.gocardless_accounts.find_by(id: gocardless_account_id)
      next unless gocardless_account
      next if gocardless_account.account_provider.present?

      accountable_type = infer_accountable_type(config[:account_type], config[:subtype])
      account = create_account_from_gocardless(gocardless_account, accountable_type, config)

      if account&.persisted?
        gocardless_account.ensure_account_provider!(account)
        gocardless_account.update!(sync_start_date: config[:sync_start_date]) if config[:sync_start_date].present?
        created_count += 1
      else
        skipped_count += 1
      end
    rescue => e
      Rails.logger.error "GocardlessItemsController#complete_account_setup - Error: #{e.message}"
      skipped_count += 1
    end

    if created_count > 0
      @gocardless_item.sync_later unless @gocardless_item.syncing?
      redirect_to accounts_path, notice: t(".success", count: created_count)
    elsif skipped_count > 0 && created_count == 0
      redirect_to accounts_path, notice: t(".all_skipped")
    else
      redirect_to setup_accounts_gocardless_item_path(@gocardless_item), alert: t(".creation_failed", error: "Unknown error")
    end
  end

  private

    # Returns the item that should carry this new bank connection.
    #
    # Configuring credentials in settings creates an item that has no requisition yet, so
    # the first connection reuses it instead of stranding it. Later connections get a
    # fresh item carrying a copy of the same account-level credentials.
    def connection_item_for_new_bank
      credentials_source = Current.family.gocardless_items.where.not(secret_id: nil).first
      return nil if credentials_source.nil?

      unconfigured = Current.family.gocardless_items
                            .where.not(secret_id: nil)
                            .where(requisition_id: nil)
                            .first
      return unconfigured if unconfigured

      Current.family.gocardless_items.create!(
        name: "GoCardless Connection",
        secret_id: credentials_source.secret_id,
        secret_key: credentials_source.secret_key
      )
    end

    # The consent link comes back from the GoCardless API, so it is not user input, but it
    # is still an off-site redirect built from a remote response. Validating the host means
    # a tampered or unexpected payload cannot bounce the user anywhere it likes. Mirrors
    # safe_redirect_to_enable_banking.
    TRUSTED_GOCARDLESS_HOSTS = %w[gocardless.com bankaccountdata.gocardless.com].freeze

    def safe_redirect_to_gocardless(url, fallback_path:, fallback_alert:)
      if valid_gocardless_redirect_url?(url)
        redirect_to url, allow_other_host: true
      else
        Rails.logger.warn("GoCardless redirect blocked - invalid URL: #{url.inspect}")
        redirect_to fallback_path, alert: fallback_alert
      end
    end

    def valid_gocardless_redirect_url?(url)
      return false if url.blank?

      uri = URI.parse(url)
      return false unless uri.scheme == "https"
      return false if uri.host.blank?

      TRUSTED_GOCARDLESS_HOSTS.any? do |host|
        uri.host == host || uri.host.end_with?(".#{host}")
      end
    rescue URI::InvalidURIError => e
      Rails.logger.warn("GoCardless invalid redirect URL: #{url.inspect} - #{e.message}")
      false
    end

    def set_gocardless_item
      @gocardless_item = Current.family.gocardless_items.find(params[:id])
    end

    # Only the credentials are user-supplied. institution_id, institution_name,
    # requisition_id, agreement_id and requisition_status are connection state written by
    # the consent flow, so they are deliberately NOT permitted here: letting a form set
    # them would allow pointing an item at an arbitrary requisition.
    def gocardless_item_params
      params.require(:gocardless_item).permit(
        :name,
        :sync_start_date,
        :secret_id,
        :secret_key
      )
    end

    def link_gocardless_account(gocardless_account, accountable_type)
      accountable_class = validated_accountable_class(accountable_type)

      account = Current.family.accounts.create!(
        name: gocardless_account.name,
        balance: gocardless_account.current_balance || 0,
        currency: gocardless_account.currency || "USD",
        accountable: accountable_class.new
      )

      gocardless_account.ensure_account_provider!(account)
      account
    end

    def create_account_from_gocardless(gocardless_account, accountable_type, config)
      accountable_class = validated_accountable_class(accountable_type)
      accountable_attrs = {}

      # Set subtype if the accountable supports it
      if config[:subtype].present? && accountable_class.respond_to?(:subtypes)
        accountable_attrs[:subtype] = config[:subtype]
      elsif accountable_class == CreditCard
        # ISO 20022 CARD positively identifies a credit card, so the default subtype is
        # safe to apply. Depository is deliberately left WITHOUT one: its default is
        # "checking", but CACC only says "cash account", so assuming checking would
        # relabel a plain current account away from the generic "Cash" category.
        accountable_attrs[:subtype] = CreditCard::DEFAULT_SUBTYPE
      end

      Current.family.accounts.create!(
        name: gocardless_account.name,
        balance: config[:balance].present? ? config[:balance].to_d : (gocardless_account.current_balance || 0),
        currency: gocardless_account.currency || "USD",
        accountable: accountable_class.new(accountable_attrs)
      )
    end

    def infer_accountable_type(account_type, subtype = nil)
      # GoCardless reports PSD2 `cashAccountType`, an ISO 20022 code, not Sure's own
      # vocabulary. Without this every code falls through to the Depository default and a
      # credit card becomes a cash account. The mapping lives on GocardlessAccount because
      # the balance sign depends on it too.
      iso = GocardlessAccount.accountable_type_for(account_type)
      return iso if iso

      case account_type&.downcase
      when "depository"
        "Depository"
      when "credit_card"
        "CreditCard"
      when "investment"
        "Investment"
      when "loan"
        "Loan"
      when "other_asset"
        "OtherAsset"
      when "other_liability"
        "OtherLiability"
      when "crypto"
        "Crypto"
      when "property"
        "Property"
      when "vehicle"
        "Vehicle"
      else
        "Depository"
      end
    end

    def validated_accountable_class(accountable_type)
      unless ALLOWED_ACCOUNTABLE_TYPES.include?(accountable_type)
        raise ArgumentError, "Invalid accountable type: #{accountable_type}"
      end

      accountable_type.constantize
    end
end

class GocardlessItemsController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!, only: [ :new_item, :create, :callback, :reauth_callback, :select_existing_account, :link_existing_account, :sync, :reauthorize, :setup_accounts, :complete_account_setup, :destroy ]
  before_action :set_gocardless_item, only: [ :sync, :reauthorize, :setup_accounts, :complete_account_setup, :destroy ]

  def index
    @gocardless_items = Current.family.gocardless_items.active.ordered
    @banks = []
  end

  def create
    Current.family.gocardless_items
           .where(pending_account_setup: true)
           .where("created_at < ?", 1.hour.ago)
           .destroy_all

    sdk = Provider::GocardlessAdapter.sdk
    return redirect_to settings_providers_path, alert: "GoCardless not configured" unless sdk

    institution_id   = params[:institution_id]
    institution_name = params[:institution_name]

    token_data  = sdk.new_token
    access_tok  = token_data["access"]
    refresh_tok = token_data["refresh"]

    agreement = sdk.with_token(access_tok).create_agreement(institution_id)

    # Create the item first so we can embed its ID in the callback URL,
    # allowing the callback to locate the exact item rather than guessing
    # by creation order (which breaks when multiple connect flows are in flight).
    item = Current.family.gocardless_items.create!(
      name:                    institution_name,
      institution_id:          institution_id,
      institution_name:        institution_name,
      agreement_id:            agreement["id"],
      agreement_expires_at:    90.days.from_now,
      access_token:            access_tok,
      refresh_token:           refresh_tok,
      access_token_expires_at: token_data["access_expires"].seconds.from_now,
      status:                  :requires_update,
      pending_account_setup:   true
    )

    requisition = sdk.create_requisition(
      institution_id: institution_id,
      agreement_id:   agreement["id"],
      redirect_url:   callback_gocardless_items_url(
        host:     request.host_with_port,
        protocol: request.protocol,
        item_id:  item.id
      ),
      reference: "sure-#{Current.family.id}-#{item.id}"
    )

    item.update!(requisition_id: requisition["id"])

    redirect_to requisition["link"], allow_other_host: true

  rescue => e
    item&.destroy rescue nil
    Rails.logger.error "GoCardless connect error: #{e.full_message}"
    redirect_to settings_providers_path, alert: "Could not connect to bank. Please try again."
  end

  def callback
    item = Current.family.gocardless_items.find_by(id: params[:item_id], pending_account_setup: true)

    return redirect_to accounts_path, alert: "Connection not found" unless item

    client = item.gocardless_client
    unless client
      Rails.logger.error "GoCardless callback: could not initialise client for item #{item.id}"
      item.update!(status: :requires_update)
      return redirect_to accounts_path, alert: "GoCardless session expired — please try connecting again."
    end

    requisition = client.get_requisition(item.requisition_id)
    gc_accounts = requisition["accounts"] || []

    if gc_accounts.empty?
      item.destroy
      return redirect_to accounts_path,
                         alert: "No accounts found — did you complete the bank login?"
    end

    gc_accounts.each do |gc_account_id|
      next if item.gocardless_accounts.exists?(account_id: gc_account_id)

      # Fetch account details — some banks (e.g. Monzo) need a moment after auth
      # before these endpoints are ready. Fail gracefully and let sync fill in later.
      # pot_ prefix = Monzo savings pot; use a descriptive fallback when details unavailable.
      is_pot   = gc_account_id.to_s.start_with?("pot_")
      name     = is_pot ? "Savings Pot" : item.institution_name
      currency = "GBP"
      balance  = nil  # nil = not yet fetched; Processor skips set_current_balance when nil

      begin
        details  = client.account_details(gc_account_id)
        acct     = details["account"] || {}
        name     = acct["name"] || acct["ownerName"] || name
        currency = acct["currency"] || currency
      rescue => e
        Rails.logger.warn "GoCardless callback: account_details failed for #{gc_account_id} — #{e.class}: #{e.message}"
      end

      begin
        balance_data = client.balances(gc_account_id)
        balances     = balance_data["balances"] || []
        bal          = balances.find { |b| b["balanceType"] == "interimAvailable" } ||
                       balances.find { |b| b["balanceType"] == "closingBooked" } ||
                       balances.first
        if bal
          balance  = bal.dig("balanceAmount", "amount")&.to_d
          currency = bal.dig("balanceAmount", "currency") || currency
        end
      rescue => e
        Rails.logger.warn "GoCardless callback: balances failed for #{gc_account_id} — #{e.class}: #{e.message}"
      end

      item.gocardless_accounts.create!(
        account_id:      gc_account_id,
        name:            name,
        currency:        currency,
        current_balance: balance
      )
    end

    item.update!(status: :good, pending_account_setup: true)
    redirect_to setup_accounts_gocardless_item_path(item)

  rescue => e
    Rails.logger.error "GoCardless callback error: #{e.class} — #{e.full_message}"
    redirect_to accounts_path, alert: "Bank connection could not be completed. Please try again."
  end

  def new_item
    @accountable_type    = params[:accountable_type]
    @countries           = Provider::GocardlessAdapter::SUPPORTED_COUNTRIES
    @gocardless_items    = Current.family.gocardless_items.active.ordered.includes(:gocardless_accounts)
    return redirect_to settings_providers_path,
      alert: "GoCardless not configured — please add your credentials first" unless Provider::GocardlessAdapter.sdk

    render "gocardless_items/new"
  end

  def select_existing_account
    @account_id          = params[:account_id]
    @gocardless_accounts = Current.family.gocardless_items
                                  .active
                                  .includes(:gocardless_accounts)
                                  .flat_map(&:gocardless_accounts)
                                  .reject { |ga| ga.account_provider.present? }
    render "gocardless_items/select_existing_account"
  end

  def link_existing_account
    account    = Current.family.accounts.find(params[:account_id])
    gc_account = GocardlessAccount
                   .joins(:gocardless_item)
                   .where(gocardless_items: { family_id: Current.family.id })
                   .find(params[:gocardless_account_id])

    if gc_account.account_provider.present?
      return redirect_to accounts_path, alert: "#{gc_account.name} is already linked to another account"
    end

    AccountProvider.create!(account: account, provider: gc_account)
    account.sync_later

    redirect_to accounts_path, notice: "#{gc_account.name} linked — syncing now"
  rescue ActiveRecord::RecordNotFound
    redirect_to accounts_path, alert: "Account not found"
  rescue => e
    Rails.logger.error "GoCardless link error: #{e.full_message}"
    redirect_to accounts_path, alert: "Could not link account. Please try again."
  end

  def sync
    @gocardless_item.sync_later unless @gocardless_item.syncing?
    redirect_to accounts_path, notice: "Syncing #{@gocardless_item.institution_name}..."
  end

  def setup_accounts
    @gocardless_accounts = @gocardless_item.gocardless_accounts
                                           .left_joins(:account_provider)
                                           .where(account_providers: { id: nil })
                                           .order(:skipped, :name)

    @rate_limited = @gocardless_accounts.none?(&:current_balance)

    @account_type_options = [
      [ "Skip this account", "skip" ],
      [ "Checking or Savings Account", "Depository" ],
      [ "Credit Card", "CreditCard" ],
      [ "Investment Account", "Investment" ],
      [ "Loan or Mortgage", "Loan" ],
      [ "Other Asset", "OtherAsset" ]
    ]

    @subtype_options = {
      "Depository" => {
        label:   "Account subtype:",
        options: Depository::SUBTYPES.map { |k, v| [ v[:long], k ] }
      },
      "CreditCard" => {
        label:   "",
        options: [],
        message: "Credit cards will be set up as credit card accounts."
      },
      "Investment" => {
        label:   "Investment type:",
        options: Investment::SUBTYPES.map { |k, v| [ v[:long], k ] }
      },
      "Loan" => {
        label:   "Loan type:",
        options: Loan::SUBTYPES.map { |k, v| [ v[:long], k ] }
      },
      "OtherAsset" => {
        label:   nil,
        options: [],
        message: "Will be set up as a general asset."
      }
    }
  end

  def complete_account_setup
    include_accounts = params.permit(include_accounts: {}).fetch(:include_accounts, {})
    account_types    = params.permit(account_types: {}).fetch(:account_types, {})
    account_subtypes = params.permit(account_subtypes: {}).fetch(:account_subtypes, {})
    permitted        = params.permit(:sync_start_date, :sync_frequency)
    sync_start_date  = permitted[:sync_start_date]
    sync_frequency   = permitted[:sync_frequency]

    item_attrs = {}
    item_attrs[:sync_start_date] = sync_start_date if sync_start_date.present?
    item_attrs[:sync_frequency]  = sync_frequency  if sync_frequency.present? && GocardlessItem.sync_frequencies.key?(sync_frequency)
    @gocardless_item.update!(item_attrs) if item_attrs.any?

    created_count = 0

    ActiveRecord::Base.transaction do
      account_types.each do |gc_account_id, selected_type|
        gc_account = @gocardless_item.gocardless_accounts.find(gc_account_id)

        unless include_accounts[gc_account_id] == "1"
          gc_account.update!(skipped: true)
          next
        end

        gc_account.update!(skipped: false) if gc_account.skipped?
        next if selected_type.blank?
        next if gc_account.account_provider.present?

        selected_subtype = account_subtypes[gc_account_id]
        selected_subtype = "credit_card" if selected_type == "CreditCard" && selected_subtype.blank?

        opening_date = (@gocardless_item.sync_start_date&.to_date || 90.days.ago.to_date) - 1.day

        # Always anchor at sync_start_date - 1 day so the account's history starts from
        # the user's selected date. When current_balance is nil (rate-limited at callback),
        # we use £0 as a placeholder; the first successful sync will set the correct current
        # balance via set_current_balance and the balance calculator works backwards from there.
        account = Account.create_and_sync(
          {
            family:                 Current.family,
            name:                   gc_account.name,
            balance:                gc_account.current_balance || 0,
            currency:               gc_account.currency || "GBP",
            accountable_type:       selected_type,
            accountable_attributes: selected_subtype.present? ? { subtype: selected_subtype } : {}
          },
          skip_initial_sync:    true,
          opening_balance_date: opening_date
        )

        AccountProvider.create!(account: account, provider: gc_account)
        created_count += 1
      end
    end

    @gocardless_item.update!(
      status:                :good,
      pending_account_setup: created_count == 0 && @gocardless_item.unlinked_accounts_count > 0
    )

    @gocardless_item.sync_later

    redirect_to accounts_path,
                notice: created_count > 0 ? "#{created_count} account(s) created — syncing now!" : "No accounts created."

  rescue => e
    Rails.logger.error "GoCardless complete_account_setup failed: #{e.full_message}"
    redirect_to accounts_path, alert: "Failed to create accounts. Please try again."
  end

  def reauthorize
    sdk = Provider::GocardlessAdapter.sdk
    return redirect_to accounts_path, alert: "GoCardless not configured" unless sdk

    token_data  = sdk.new_token
    access_tok  = token_data["access"]
    refresh_tok = token_data["refresh"]

    agreement = sdk.with_token(access_tok).create_agreement(@gocardless_item.institution_id)

    requisition = sdk.create_requisition(
      institution_id: @gocardless_item.institution_id,
      agreement_id:   agreement["id"],
      redirect_url:   reauth_callback_gocardless_items_url(
        host:     request.host_with_port,
        protocol: request.protocol,
        item_id:  @gocardless_item.id
      ),
      reference: "sure-#{Current.family.id}-#{Time.now.to_i}-reauth"
    )

    @gocardless_item.update!(
      requisition_id:          requisition["id"],
      agreement_id:            agreement["id"],
      agreement_expires_at:    90.days.from_now,
      access_token:            access_tok,
      refresh_token:           refresh_tok,
      access_token_expires_at: token_data["access_expires"].seconds.from_now,
      status:                  :requires_update
    )

    redirect_to requisition["link"], allow_other_host: true

  rescue => e
    Rails.logger.error "GoCardless reauthorize error: #{e.full_message}"
    redirect_to accounts_path, alert: "Could not initiate reauthorisation. Please try again."
  end

  def reauth_callback
    item = Current.family.gocardless_items.find_by(id: params[:item_id], status: :requires_update)
    return redirect_to accounts_path, alert: "Connection not found" unless item
    return redirect_to accounts_path, alert: "Connection not found" unless item.requisition_id.present?

    client = item.gocardless_client
    unless client
      item.update!(status: :requires_update)
      return redirect_to accounts_path, alert: "GoCardless session expired — please reauthorise again."
    end

    requisition  = client.get_requisition(item.requisition_id)
    gc_account_ids = requisition["accounts"] || []

    return redirect_to accounts_path, alert: "No accounts found — did you complete the bank login?" if gc_account_ids.empty?

    gc_account_ids.each do |gc_account_id|
      next if item.gocardless_accounts.exists?(account_id: gc_account_id)

      item.gocardless_accounts.create!(
        account_id: gc_account_id,
        name:       item.institution_name,
        currency:   "GBP"
      )
    end

    item.update!(status: :good)
    item.sync_later

    redirect_to accounts_path, notice: "#{item.institution_name} reauthorised — syncing now!"

  rescue => e
    Rails.logger.error "GoCardless reauth_callback error: #{e.full_message}"
    redirect_to accounts_path, alert: "Reauthorisation could not be completed. Please try again."
  end

  def destroy
    @gocardless_item.destroy_later
    redirect_to settings_providers_path, notice: "Bank disconnected"
  end

  def search_banks
    sdk = Provider::GocardlessAdapter.sdk
    return render json: [] unless sdk

    country    = params.fetch(:country, "gb").downcase
    country    = "gb" unless Provider::GocardlessAdapter::SUPPORTED_COUNTRIES.key?(country)
    token_data = sdk.new_token
    banks      = sdk.with_token(token_data["access"]).institutions(country: country)
    query      = params[:q].to_s.downcase

    filtered = banks.select { |b| b["name"].downcase.include?(query) }
                    .first(20)
                    .map { |b| { id: b["id"], name: b["name"], logo: b["logo"] } }

    render json: filtered
  end

  private

    def set_gocardless_item
      @gocardless_item = Current.family.gocardless_items.find(params[:id])
    end
end
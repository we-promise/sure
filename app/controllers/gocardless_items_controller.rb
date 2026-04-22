class GocardlessItemsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_gocardless_item, only: [ :sync, :setup_accounts, :complete_account_setup, :destroy ]

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

    agreement   = sdk.with_token(access_tok).create_agreement(institution_id)

    requisition = sdk.create_requisition(
      institution_id: institution_id,
      agreement_id:   agreement["id"],
      redirect_url:   callback_gocardless_items_url(
        host:     request.host_with_port,
        protocol: request.protocol
      ),
      reference: "sure-#{Current.family.id}-#{Time.now.to_i}"
    )

    Current.family.gocardless_items.create!(
      name:                    institution_name,
      institution_id:          institution_id,
      institution_name:        institution_name,
      requisition_id:          requisition["id"],
      agreement_id:            agreement["id"],
      access_token:            access_tok,
      refresh_token:           refresh_tok,
      access_token_expires_at: token_data["access_expires"].seconds.from_now,
      status:                  :requires_update,
      pending_account_setup:   true
    )

    redirect_to requisition["link"], allow_other_host: true

  rescue => e
    Rails.logger.error "GoCardless connect error: #{e.message}"
    redirect_to settings_providers_path, alert: "Could not connect to bank: #{e.message}"
  end

  def callback
    item = Current.family.gocardless_items
                  .where(pending_account_setup: true)
                  .order(created_at: :desc)
                  .first

    return redirect_to accounts_path, alert: "Connection not found" unless item

    client      = item.gocardless_client
    requisition = client.get_requisition(item.requisition_id)
    gc_accounts = requisition["accounts"] || []

    if gc_accounts.empty?
      item.destroy
      return redirect_to accounts_path,
                         alert: "No accounts found — did you complete the bank login?"
    end

    gc_accounts.each_with_index do |gc_account_id, index|
      next if item.gocardless_accounts.exists?(account_id: gc_account_id)

      sleep(0.5) if index > 0

      details  = client.account_details(gc_account_id)
      acct     = details["account"] || {}

      balance_data    = client.balances(gc_account_id)
      balances        = balance_data["balances"] || []
      bal             = balances.find { |b| b["balanceType"] == "interimAvailable" } ||
                        balances.find { |b| b["balanceType"] == "closingBooked" } ||
                        balances.first
      current_balance = bal&.dig("balanceAmount", "amount")&.to_d || 0
      currency        = bal&.dig("balanceAmount", "currency") ||
                        acct["currency"] || "GBP"

      item.gocardless_accounts.create!(
        account_id:      gc_account_id,
        name:            acct["name"] || acct["ownerName"] || item.institution_name,
        currency:        currency,
        current_balance: current_balance
      )
    end

    item.update!(status: :good, pending_account_setup: true)
    redirect_to setup_accounts_gocardless_item_path(item)

  rescue => e
    Rails.logger.error "GoCardless callback error: #{e.message}"
    redirect_to accounts_path, alert: "Connection error: #{e.message}"
  end

  def new_item
    @accountable_type = params[:accountable_type]
    sdk = Provider::GocardlessAdapter.sdk
    return redirect_to settings_providers_path,
      alert: "GoCardless not configured — please add your credentials first" unless sdk

    token_data = sdk.new_token
    @banks     = sdk.with_token(token_data["access"]).institutions(country: "gb")
    render "gocardless_items/new"
  end

  def select_existing_account
    @account_id          = params[:account_id]
    @gocardless_accounts = Current.family.gocardless_items
                                  .active
                                  .includes(:gocardless_accounts)
                                  .flat_map(&:gocardless_accounts)
    render "gocardless_items/select_existing_account"
  end

  def link_existing_account
    account    = Current.family.accounts.find(params[:account_id])
    gc_account = GocardlessAccount.find(params[:gocardless_account_id])

    AccountProvider.create!(
      account:  account,
      provider: gc_account
    )

    redirect_to accounts_path, notice: "#{gc_account.name} linked successfully"
  rescue => e
    redirect_to accounts_path, alert: "Could not link account: #{e.message}"
  end

  def sync
    @gocardless_item.sync_later unless @gocardless_item.syncing?
    redirect_to accounts_path, notice: "Syncing #{@gocardless_item.institution_name}..."
  end

  def setup_accounts
    @gocardless_accounts = @gocardless_item.gocardless_accounts
                                           .left_joins(:account_provider)
                                           .where(account_providers: { id: nil })

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
    account_types = params[:account_types] || {}

    @gocardless_item.update!(sync_start_date: params[:sync_start_date]) if params[:sync_start_date].present?

    created_count = 0
    skipped_count = 0

    ActiveRecord::Base.transaction do
      account_types.each do |gc_account_id, selected_type|
        if selected_type == "skip" || selected_type.blank?
          skipped_count += 1
          next
        end

        gc_account = @gocardless_item.gocardless_accounts.find(gc_account_id)
        next if gc_account.account_provider.present?

        selected_subtype = params.dig(:account_subtypes, gc_account_id)
        selected_subtype = "credit_card" if selected_type == "CreditCard" && selected_subtype.blank?

        account = Account.create_and_sync(
          {
            family:                 Current.family,
            name:                   gc_account.name,
            balance:                gc_account.current_balance || 0,
            currency:               gc_account.currency || "GBP",
            accountable_type:       selected_type,
            accountable_attributes: selected_subtype.present? ? { subtype: selected_subtype } : {}
          },
          skip_initial_sync: true
        )

        AccountProvider.create!(account: account, provider: gc_account)
        created_count += 1
      end
    end

    @gocardless_item.update!(
      status:                :good,
      pending_account_setup: created_count == 0 && @gocardless_item.unlinked_accounts_count > 0
    )

    @gocardless_item.sync_later if created_count > 0

    redirect_to accounts_path,
                notice: created_count > 0 ? "#{created_count} account(s) created and syncing!" : "No accounts created."

  rescue => e
    Rails.logger.error "GoCardless complete_account_setup failed: #{e.message}"
    redirect_to accounts_path, alert: "Failed to create accounts: #{e.message}"
  end

  def destroy
    @gocardless_item.destroy_later
    redirect_to settings_providers_path, notice: "Bank disconnected"
  end

  def search_banks
    sdk = Provider::GocardlessAdapter.sdk
    return render json: [] unless sdk

    token_data = sdk.new_token
    banks      = sdk.with_token(token_data["access"]).institutions(country: "gb")
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
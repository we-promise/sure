class Settings::GocardlessItemsController < ApplicationController
  before_action :authenticate_user!

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

    # Get fresh tokens
    token_data  = sdk.new_token
    access_tok  = token_data["access"]
    refresh_tok = token_data["refresh"]

    # Create agreement
    agreement = sdk.with_token(access_tok).create_agreement(institution_id)

    # Create requisition with callback URL
    requisition = sdk.create_requisition(
      institution_id: institution_id,
      agreement_id:   agreement["id"],
      redirect_url: callback_settings_gocardless_items_url(
        host: request.host_with_port,
        protocol: request.protocol
      ),
      reference:      "sure-#{Current.family.id}-#{Time.now.to_i}"
    )

    # Save pending item
    Current.family.gocardless_items.create!(
      name:                  institution_name,
      institution_id:        institution_id,
      institution_name:      institution_name,
      requisition_id:        requisition["id"],
      agreement_id:          agreement["id"],
      access_token:          access_tok,
      refresh_token:         refresh_tok,
      access_token_expires_at: token_data["access_expires"].seconds.from_now,
      status:                :requires_update,
      pending_account_setup: true
    )

    # Send user to their bank
    redirect_to requisition["link"], allow_other_host: true

  rescue => e
    Rails.logger.error "GoCardless connect error: #{e.message}"
    redirect_to settings_providers_path, alert: "Could not connect to bank: #{e.message}"
  end

  def callback
    # Find the pending item for this family
    item = Current.family.gocardless_items
                  .where(pending_account_setup: true)
                  .order(created_at: :desc)
                  .first

    return redirect_to settings_providers_path, alert: "Connection not found" unless item

    client      = item.gocardless_client
    requisition = client.get_requisition(item.requisition_id)
    gc_accounts = requisition["accounts"] || []

    if gc_accounts.empty?
      item.destroy
      return redirect_to settings_providers_path,
                         alert: "No accounts found — did you complete the bank login?"
    end

    gc_accounts.each do |gc_account_id|
      next if item.gocardless_accounts.exists?(account_id: gc_account_id)

      details  = client.account_details(gc_account_id)
      acct     = details["account"] || {}
      currency = acct["currency"] || "GBP"
      name     = acct["name"] || acct["ownerName"] || item.institution_name

      # Create the sure.am account
      account = Current.family.accounts.create!(
        name:         name,
        currency:     currency,
        accountable:  OtherAsset.new
      )

      item.gocardless_accounts.create!(
        account:    account,
        account_id: gc_account_id,
        name:       name,
        currency:   currency
      )
    end

    item.update!(status: :good, pending_account_setup: false)

    # Kick off first sync
    GoCardlessSyncJob.perform_later(item.id)

    redirect_to settings_providers_path,
                notice: "#{item.institution_name} connected successfully!"

  rescue => e
    Rails.logger.error "GoCardless callback error: #{e.message}"
    redirect_to settings_providers_path, alert: "Connection error: #{e.message}"
  end

  def new_item
    @accountable_type = params[:accountable_type]
      sdk = Provider::GocardlessAdapter.sdk
    return redirect_to settings_providers_path,
    alert: "GoCardless not configured — please add your credentials first" unless sdk

    token_data = sdk.new_token
    @banks = sdk.with_token(token_data["access"]).institutions(country: "gb")
    render "settings/gocardless_items/new"
  end

  def select_existing_account
    @account_id = params[:account_id]
    @gocardless_accounts = Current.family.gocardless_items
                                .active
                                .includes(:gocardless_accounts)
                                .flat_map(&:gocardless_accounts)
    render "settings/gocardless_items/select_existing"
  end
  
  def destroy
    item = Current.family.gocardless_items.find(params[:id])
    item.destroy_later
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
end
class BankConnectionsController < ApplicationController
  before_action :set_bank_connection, only: %i[show destroy sync setup_accounts complete_account_setup]

  def index
    @bank_connections = Current.family.bank_connections.active.ordered
    render layout: "settings"
  end

  def show
  end

  def new
    @provider_key = params[:provider]&.to_sym
    @provider_meta = Provider::Banks::Registry.find(@provider_key) if @provider_key
    @bank_connection = Current.family.bank_connections.build(provider: @provider_key)
  end

  def create
    provider_key = bank_connection_params[:provider]&.to_sym
    credentials = (params[:credentials] || {}).to_unsafe_h

    return render_error("Please select a provider.") unless provider_key

    begin
      @bank_connection = Current.family.create_bank_connection!(
        provider: provider_key,
        credentials: credentials,
        item_name: params[:name].presence
      )

      redirect_to bank_connections_path, notice: "Connection added. Your accounts will appear shortly as they sync."
    rescue ArgumentError => e
      render_error(e.message)
    rescue => e
      Rails.logger.error("Bank connection error: #{e.message}")
      render_error("An unexpected error occurred. Please try again or contact support.")
    end
  end

  def destroy
    @bank_connection.destroy_later
    redirect_to bank_connections_path, notice: "Connection will be removed"
  end

  def sync
    @bank_connection.sync_later
    redirect_to bank_connection_path(@bank_connection), notice: "Sync started"
  end

  def setup_accounts
    @external_accounts = @bank_connection.bank_external_accounts.includes(:account).where(accounts: { id: nil })
    @account_type_options = [
      ["Checking or Savings Account", "Depository"],
      ["Skip - don't add", "Skip"]
    ]
    @subtype_options = {
      "Depository" => { label: "Account Subtype:", options: Depository::SUBTYPES.map { |k, v| [v[:long], k] } }
    }
  end

  def complete_account_setup
    account_types = params[:account_types] || {}
    account_subtypes = params[:account_subtypes] || {}

    account_types.each do |ext_account_id, selected_type|
      next if selected_type == "Skip"
      ext_account = @bank_connection.bank_external_accounts.find(ext_account_id)
      next if ext_account.account.present?

      account_params = {
        name: ext_account.name,
        currency: ext_account.currency,
        balance: ext_account.current_balance || 0,
        bank_external_account: ext_account,
        family: Current.family
      }

      case selected_type
      when "Depository"
        subtype = account_subtypes[ext_account_id] || "checking"
        Account.create_depository!(account_params.merge(accountable_attributes: { subtype: subtype }))
      else
        Rails.logger.error("Unknown account type selected: #{selected_type}")
        next
      end
    end

    @bank_connection.update!(pending_account_setup: false)
    redirect_to bank_connections_path, notice: "Accounts have been set up successfully!"
  end

  private
    def set_bank_connection
      @bank_connection = Current.family.bank_connections.find(params[:id])
    end

    def bank_connection_params
      params.require(:bank_connection).permit(:provider)
    end

    def render_error(message)
      @bank_connection = Current.family.bank_connections.build
      flash.now[:alert] = message
      render :new, status: :unprocessable_entity
    end
end


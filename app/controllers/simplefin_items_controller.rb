class SimplefinItemsController < ApplicationController
  before_action :set_simplefin_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def index
    @simplefin_items = Current.family.simplefin_items.active.ordered
    render layout: "settings"
  end

  def show
  end

  def edit
    # For SimpleFin, editing means providing a new setup token to replace expired access
    @simplefin_item.setup_token = nil # Clear any existing setup token
  end

  def update
    setup_token = simplefin_params[:setup_token]

    return render_error("Please enter a SimpleFin setup token.") if setup_token.blank?

    begin
      # Create new SimpleFin item data with updated token
      updated_item = Current.family.create_simplefin_item!(
        setup_token: setup_token,
        item_name: @simplefin_item.name
      )

      # Transfer accounts from old item to new item
      @simplefin_item.simplefin_accounts.each do |old_account|
        if old_account.account.present?
          # Find matching account in new item by account_id
          new_account = updated_item.simplefin_accounts.find_by(account_id: old_account.account_id)
          if new_account
            # Transfer the Maybe account association
            old_account.account.update!(simplefin_account_id: new_account.id)
            # Remove old association
            old_account.update!(account: nil)
          end
        end
      end

      # Mark old item for deletion
      @simplefin_item.destroy_later

      # Clear any requires_update status on new item
      updated_item.update!(status: :good)

      redirect_to accounts_path, notice: t(".success")
    rescue ArgumentError, URI::InvalidURIError
      render_error("Invalid setup token. Please check that you copied the complete token from SimpleFin Bridge.", setup_token)
    rescue Provider::Simplefin::SimplefinError => e
      error_message = case e.error_type
      when :token_compromised
        "The setup token may be compromised, expired, or already used. Please create a new one."
      else
        "Failed to update connection: #{e.message}"
      end
      render_error(error_message, setup_token)
    rescue => e
      Rails.logger.error("SimpleFin connection update error: #{e.message}")
      render_error("An unexpected error occurred. Please try again or contact support.", setup_token)
    end
  end

  def new
    @simplefin_item = Current.family.simplefin_items.build
  end

  def create
    setup_token = simplefin_params[:setup_token]

    return render_error("Please enter a SimpleFin setup token.") if setup_token.blank?

    begin
      @simplefin_item = Current.family.create_simplefin_item!(
        setup_token: setup_token,
        item_name: "SimpleFin Connection"
      )

      redirect_to accounts_path, notice: t(".success")
    rescue ArgumentError, URI::InvalidURIError
      render_error("Invalid setup token. Please check that you copied the complete token from SimpleFin Bridge.", setup_token)
    rescue Provider::Simplefin::SimplefinError => e
      error_message = case e.error_type
      when :token_compromised
        "The setup token may be compromised, expired, or already used. Please create a new one."
      else
        "Failed to connect: #{e.message}"
      end
      render_error(error_message, setup_token)
    rescue => e
      Rails.logger.error("SimpleFin connection error: #{e.message}")
      render_error("An unexpected error occurred. Please try again or contact support.", setup_token)
    end
  end

  def destroy
    @simplefin_item.destroy_later
    redirect_to accounts_path, notice: t(".success")
  end

  def sync
    unless @simplefin_item.syncing?
      @simplefin_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def setup_accounts
    @simplefin_accounts = @simplefin_item.simplefin_accounts.includes(:account).where(accounts: { id: nil })
    @account_type_options = [
      [ "Checking or Savings Account", "Depository" ],
      [ "Credit Card", "CreditCard" ],
      [ "Investment Account", "Investment" ],
      [ "Loan or Mortgage", "Loan" ],
      [ "Other Asset", "OtherAsset" ]
    ]

    # Subtype options for each account type
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

    account_types.each do |simplefin_account_id, selected_type|
      simplefin_account = @simplefin_item.simplefin_accounts.find(simplefin_account_id)
      selected_subtype = account_subtypes[simplefin_account_id]

      # Default subtype for CreditCard since it only has one option
      selected_subtype = "credit_card" if selected_type == "CreditCard" && selected_subtype.blank?

      # Create account with user-selected type and subtype
      account = Account.create_from_simplefin_account(
        simplefin_account,
        selected_type,
        selected_subtype
      )
      simplefin_account.update!(account: account)
    end

    # Clear pending status and mark as complete
    @simplefin_item.update!(pending_account_setup: false)

    # Trigger a sync to process the imported SimpleFin data (transactions and holdings)
    @simplefin_item.sync_later

    redirect_to accounts_path, notice: t(".success")
  end

  private

    def set_simplefin_item
      @simplefin_item = Current.family.simplefin_items.find(params[:id])
    end

    def simplefin_params
      params.require(:simplefin_item).permit(:setup_token)
    end

    def render_error(message, setup_token = nil)
      @simplefin_item = Current.family.simplefin_items.build(setup_token: setup_token)
      @error_message = message
      render :new, status: :unprocessable_entity
    end
end

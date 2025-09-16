class SimplefinItemsController < ApplicationController
  before_action :set_simplefin_item, only: [ :show, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def index
    @simplefin_items = Current.family.simplefin_items.active.ordered
    render layout: "settings"
  end

  def show
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

      redirect_to simplefin_items_path, notice: "SimpleFin connection added successfully! Your accounts will appear shortly as they sync in the background."
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
    redirect_to simplefin_items_path, notice: "SimpleFin connection will be removed"
  end

  def sync
    @simplefin_item.sync_later
    redirect_to simplefin_item_path(@simplefin_item), notice: "Sync started"
  end

  def setup_accounts
    @simplefin_accounts = @simplefin_item.simplefin_accounts.includes(:account).where(accounts: { id: nil })
    @account_type_options = [
      [ "Checking or Savings Account", "Depository" ],
      [ "Credit Card", "CreditCard" ],
      [ "Investment Account", "Investment" ],
      [ "Loan or Mortgage", "Loan" ],
      [ "Other Asset", "OtherAsset" ],
      [ "Skip - don't add", "Skip" ]
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
      # Skip accounts that the user chose not to add
      next if selected_type == "Skip"

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

    # Schedule account syncs for the newly created accounts
    @simplefin_item.schedule_account_syncs

    redirect_to simplefin_items_path, notice: "SimpleFin accounts have been set up successfully!"
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

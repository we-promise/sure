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

    # Validate the token format first
    if setup_token.blank?
      @simplefin_item = Current.family.simplefin_items.build
      @error_message = "Please enter a SimpleFin setup token."
      render :new, status: :unprocessable_entity
      return
    end

    begin
      # Test if it's valid base64
      decoded = Base64.decode64(setup_token)
      unless decoded.valid_encoding? && decoded.start_with?("http")
        raise ArgumentError, "Invalid setup token format"
      end

      access_url = simplefin_provider.claim_access_url(setup_token)

      @simplefin_item = Current.family.simplefin_items.build(
        access_url: access_url,
        name: "SimpleFin Connection"
      )

      if @simplefin_item.save
        # Immediately sync to get account and institution data
        @simplefin_item.sync_later

        redirect_to simplefin_items_path, notice: "SimpleFin connection added successfully! Your accounts will appear shortly as they sync in the background."
      else
        @error_message = @simplefin_item.errors.full_messages.join(", ")
        render :new, status: :unprocessable_entity
      end
    rescue ArgumentError, URI::InvalidURIError => e
      @simplefin_item = Current.family.simplefin_items.build(setup_token: setup_token)
      @error_message = "Invalid setup token. Please check that you copied the complete token from SimpleFin Bridge."
      render :new, status: :unprocessable_entity
    rescue Provider::Simplefin::SimplefinError => e
      @simplefin_item = Current.family.simplefin_items.build(setup_token: setup_token)
      case e.error_type
      when :token_compromised
        @error_message = "The setup token may be compromised, expired, or already used. Please create a new one."
      else
        @error_message = "Failed to connect: #{e.message}"
      end
      render :new, status: :unprocessable_entity
    rescue => e
      Rails.logger.error("SimpleFin connection error: #{e.message}")
      @simplefin_item = Current.family.simplefin_items.build(setup_token: setup_token)
      @error_message = "An unexpected error occurred. Please try again or contact support."
      render :new, status: :unprocessable_entity
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
    @simplefin_accounts = @simplefin_item.simplefin_accounts
    @account_type_options = [
      ['Checking or Savings Account', 'Depository'],
      ['Credit Card', 'CreditCard'], 
      ['Investment Account', 'Investment'],
      ['Loan or Mortgage', 'Loan'],
      ['Other Asset', 'OtherAsset']
    ]
    
    # Subtype options for each account type
    @depository_subtypes = Depository::SUBTYPES.map { |k, v| [v[:long], k] }
    @credit_card_subtypes = CreditCard::SUBTYPES.map { |k, v| [v[:long], k] }
    @investment_subtypes = Investment::SUBTYPES.map { |k, v| [v[:long], k] }
    @loan_subtypes = Loan::SUBTYPES.map { |k, v| [v[:long], k] }
  end

  def complete_account_setup
    account_types = params[:account_types] || {}
    account_subtypes = params[:account_subtypes] || {}
    
    account_types.each do |simplefin_account_id, selected_type|
      simplefin_account = @simplefin_item.simplefin_accounts.find(simplefin_account_id)
      selected_subtype = account_subtypes[simplefin_account_id]
      
      # Create account with user-selected type and subtype
      account = Account.create_from_simplefin_account_with_type_and_subtype(
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

    def simplefin_provider
      @simplefin_provider ||= Provider::Simplefin.new
    end
end

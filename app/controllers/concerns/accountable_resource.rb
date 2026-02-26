module AccountableResource
  extend ActiveSupport::Concern

  included do
    include Periodable

    before_action :set_account, only: [ :show, :edit, :update ]
    before_action :set_link_options, only: :new
  end

  class_methods do
    # Defines or retrieves the permitted attributes for the accountable model
    def permitted_accountable_attributes(*attrs)
      @permitted_accountable_attributes = attrs if attrs.any?
      @permitted_accountable_attributes ||= [ :id ]
    end
  end

  # Builds a new account with a default currency and accountable type
  def new
    @account = Current.family.accounts.build(
      currency: Current.family.currency,
      accountable: accountable_type.new
    )
  end

  # Displays the account with paginated, reverse-chronological entries
  def show
    @chart_view = params[:chart_view] || "balance"
    @q = params.fetch(:q, {}).permit(:search)
    entries = @account.entries.search(@q).reverse_chronological

    @pagy, @entries = pagy(entries, limit: safe_per_page(10))
  end

  # Renders the edit form for the account
  def edit
  end

  # Creates a new account, triggers sync, and locks saved attributes
  def create
    @account = Current.family.accounts.create_and_sync(account_params.except(:return_to))
    @account.lock_saved_attributes!

    redirect_to account_params[:return_to].presence || @account, notice: t("accounts.create.success", type: accountable_type.name.underscore.humanize)
  end

  # Updates account attributes and optionally adjusts the current balance
  def update
    # Handle balance update if the value actually changed
    if account_params[:balance].present? && account_params[:balance].to_d != @account.balance
      result = @account.set_current_balance(account_params[:balance].to_d)
      unless result.success?
        @error_message = result.error_message
        render :edit, status: :unprocessable_entity
        return
      end
    end

    # Update remaining account attributes
    update_params = account_params.except(:return_to, :balance, :currency)
    unless @account.update(update_params)
      @error_message = @account.errors.full_messages.join(", ")
      render :edit, status: :unprocessable_entity
      return
    end

    @account.lock_saved_attributes!
    redirect_back_or_to account_path(@account), notice: t("accounts.update.success", type: accountable_type.name.underscore.humanize)
  end

  private
    # Loads available provider configurations for linking a new account
    def set_link_options
      account_type_name = accountable_type.name

      # Get all available provider configs dynamically for this account type
      @provider_configs = Provider::Factory.connection_configs_for_account_type(
        account_type: account_type_name,
        family: Current.family
      )
    end

    # Infers the accountable model class from the controller name
    def accountable_type
      controller_name.classify.constantize
    end

    # Finds and sets the account from the current family
    def set_account
      @account = Current.family.accounts.find(params[:id])
    end

    # Permits the allowed account parameters from the request
    def account_params
      params.require(:account).permit(
        :name, :balance, :subtype, :currency, :accountable_type, :return_to,
        :institution_name, :institution_domain, :notes, :excluded,
        accountable_attributes: self.class.permitted_accountable_attributes
      )
    end
end

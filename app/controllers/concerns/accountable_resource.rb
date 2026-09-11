module AccountableResource
  extend ActiveSupport::Concern

  included do
    include Periodable, StreamExtensions

    before_action :set_account, only: [ :show ]
    before_action :set_manageable_account, only: [ :edit, :update ]
    before_action :set_link_options, only: :new
  end

  class_methods do
    def permitted_accountable_attributes(*attrs)
      @permitted_accountable_attributes = attrs if attrs.any?
      @permitted_accountable_attributes ||= [ :id ]
    end
  end

  def new
    @account = Current.family.accounts.build(
      currency: Current.family.currency,
      accountable: accountable_type.new
    )
  end

  def show
    @chart_view = params[:chart_view] || "balance"
    @q = params.fetch(:q, {}).permit(:search)
    entries = @account.entries.search(@q).reverse_chronological

    @pagy, @entries = pagy(entries, limit: safe_per_page(10))
  end

  def edit
  end

  def create
    opening_balance_date = begin
      account_params[:opening_balance_date].presence&.to_date
    rescue Date::Error
      nil
    end || (Time.zone.today - 2.years)
    Account.transaction do
      @account = Current.family.accounts.create_and_sync(
        account_params.except(:return_to, :opening_balance_date).merge(owner: Current.user),
        opening_balance_date: opening_balance_date
      )
      @account.lock_saved_attributes!
    end

    # Prefer the form-carried return_to, then the session value StoreLocation
    # captured from `?return_to=` (survives multi-step flows where the param
    # isn't threaded), then the account page. The form param is sanitized here
    # (the session value is already filtered at store time); the session is
    # consumed with delete so a stale value can't leak into a later flow.
    return_path = safe_return_to(account_params[:return_to]) || session.delete(:return_to).presence || @account
    redirect_to return_path,
                notice: t("accounts.create.success", type: accountable_type.name.underscore.humanize)
  rescue ActiveRecord::RecordInvalid => e
    # `create_and_sync` saves with `save!`. A validation the user can trip from
    # the form (a half-filled loan rate change, say) must come back as the form
    # with the error and what they typed, not as the generic 422 page. The
    # transaction above has already rolled back. The record on the exception is
    # usually the unsaved account with its nested accountable still attached --
    # but the opening valuation's `entries.create!` or `lock_saved_attributes!`
    # can raise too, and then it is an Entry or the accountable, neither of
    # which the form can render. Recover the account through it, or rebuild
    # it from what was submitted so the form comes back filled in rather
    # than blank.
    @account = if e.record.is_a?(Account)
      e.record
    else
      e.record.try(:account) ||
        Current.family.accounts.build(account_params.except(:return_to, :opening_balance_date))
    end
    @error_message = e.record.errors.full_messages.join(", ").presence || e.message
    # The `new` template's method-selection branch reads `@provider_configs`,
    # which the `new` action's before_action sets up; this render needs it too.
    set_link_options
    render :new, status: :unprocessable_entity
  end

  def update
    # The balance change and the attribute update are one form, so they commit
    # or roll back as one. `set_current_balance` writes a valuation and the
    # account's cached balance; before this, a validation failing on the
    # attributes (a half-filled loan rate change, say) returned 422 with the
    # balance half of the rejected form already committed.
    saved = Account.transaction do
      # Handle balance update if the value actually changed
      if account_params[:balance].present? && account_params[:balance].to_d != @account.balance
        result = @account.set_current_balance(account_params[:balance].to_d)
        unless result.success?
          @error_message = result.error_message
          raise ActiveRecord::Rollback
        end
      end

      # Update remaining account attributes. Note: currency is intentionally allowed
      # here so all account types (depositories, credit cards, loans, etc.) can
      # have their currency changed via this shared update path.
      update_params = account_params.except(:return_to, :balance, :opening_balance_date)
      unless @account.update(update_params)
        @error_message = @account.errors.full_messages.join(", ")
        raise ActiveRecord::Rollback
      end

      # Inside the transaction, as `create` does: the locks are saved with
      # `update!`, and a raise there after the commit left the balance and the
      # attributes above in place behind a failed request.
      @account.lock_saved_attributes!

      true
    rescue ActiveRecord::RecordInvalid => e
      @error_message = e.record.errors.full_messages.join(", ").presence || e.message
      raise ActiveRecord::Rollback
    end

    unless saved
      render :edit, status: :unprocessable_entity
      return
    end

    redirect_back_or_to account_path(@account), notice: t("accounts.update.success", type: accountable_type.name.underscore.humanize)
  end

  private
    def set_link_options
      account_type_name = accountable_type.name

      # Get all available provider configs dynamically for this account type
      @provider_configs = Provider::Factory.connection_configs_for_account_type(
        account_type: account_type_name,
        family: Current.family
      )
    end

    def accountable_type
      controller_name.classify.constantize
    end

    def set_account
      @account = Current.user.accessible_accounts.find(params[:id])
    end

    def set_manageable_account
      @account = Current.user.accessible_accounts.find(params[:id])
      require_account_permission!(@account)
    end

    def account_params
      params.require(:account).permit(
        :name, :balance, :subtype, :currency, :accountable_type, :return_to,
        :opening_balance_date,
        :institution_name, :institution_domain, :notes, :exclude_from_reports,
        :enable_category_matcher,
        accountable_attributes: self.class.permitted_accountable_attributes
      )
    end
end

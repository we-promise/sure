class InstallmentsController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes(
    :id, :installment_cost, :total_term, :current_term,
    :payment_period, :first_payment_date, :subtype
  )

  def create
    @account = nil
    installment_data = accountable_params

    ActiveRecord::Base.transaction do
      calculated_balance = calculate_balance(installment_data)

      account_attrs = account_params.except(:return_to).to_h.deep_symbolize_keys
      account_attrs[:balance] = calculated_balance
      account_attrs[:currency] = account_attrs[:currency].presence || Current.family.currency

      @account = Current.family.accounts.create_and_sync(account_attrs)

      source_account_id = params.dig(:account, :source_account_id).presence
      Installment::Creator.new(@account.accountable, source_account_id: source_account_id).call

      @account.lock_saved_attributes!
    end

    redirect_to account_params[:return_to].presence || @account,
                notice: t("accounts.create.success", type: "Installment")
  rescue ActiveRecord::RecordInvalid => e
    @account ||= Current.family.accounts.build(
      currency: Current.family.currency,
      accountable: Installment.new(accountable_params)
    )
    render :new, status: :unprocessable_entity
  end

  def update
    installment = @account.accountable
    installment_data = accountable_params

    ActiveRecord::Base.transaction do
      update_params = account_params.except(:return_to, :balance, :currency).to_h.deep_symbolize_keys
      update_params.delete(:accountable_attributes)

      unless @account.update(update_params)
        @error_message = @account.errors.full_messages.join(", ")
        render :edit, status: :unprocessable_entity
        return
      end

      schedule_affecting_fields = %w[installment_cost total_term current_term payment_period first_payment_date]
      installment.assign_attributes(installment_data)
      schedule_changed = schedule_affecting_fields.any? { |field| installment.send("#{field}_changed?") }

      installment.save!

      if schedule_changed
        remove_installment_activity(installment)
        source_account_id = params.dig(:account, :source_account_id).presence
        Installment::Creator.new(installment, source_account_id: source_account_id).call
      end

      @account.lock_saved_attributes!
    end

    redirect_back_or_to account_path(@account), notice: t("accounts.update.success", type: "Installment")
  rescue ActiveRecord::RecordInvalid
    @error_message = @account.errors.full_messages.join(", ")
    render :edit, status: :unprocessable_entity
  end

  private

    def set_link_options
      @provider_configs = []
    end

    def accountable_params
      params.require(:account).fetch(:accountable_attributes, {}).permit(
        :installment_cost, :total_term, :current_term, :payment_period,
        :first_payment_date
      )
    end

    def calculate_balance(installment_data)
      cost = installment_data[:installment_cost].to_d
      total = installment_data[:total_term].to_i
      current = (installment_data[:current_term] || 0).to_i

      cost * (total - current)
    end

    def remove_installment_activity(installment)
      entries = @account.entries.joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
                        .where(entryable_type: "Transaction")
                        .where("transactions.extra ->> 'installment_id' = ?", installment.id.to_s)

      entry_ids = entries.pluck(:id)
      Entry.where(id: entry_ids).destroy_all
      RecurringTransaction.where(installment_id: installment.id).destroy_all
    end
end

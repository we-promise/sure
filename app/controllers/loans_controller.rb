class LoansController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes(
    :id, :rate_type, :interest_rate, :term_months, :initial_balance
  )

  def create
    # Check if this is an installment mode submission
    if installment_params.present? && installment_params[:installment_cost].present?
      create_with_installment
    else
      super
    end
  end

  def update
    if @account.installment.present? || installment_params.present?
      update_with_installment
    else
      super
    end
  end

  private

    def create_with_installment
      @account = nil

      ActiveRecord::Base.transaction do
        # Create account with calculated balance
        installment_data = installment_params
        calculated_balance = calculate_current_balance_from_params(installment_data)

        account_attrs = ensure_installment_account_params.merge(balance: calculated_balance)
        @account = Current.family.accounts.create!(account_attrs.except(:installment_attributes, :return_to))

        # Create installment (most_recent_payment_date is calculated, not stored)
        installment = @account.create_installment!(
          installment_cost: installment_data[:installment_cost],
          total_term: installment_data[:total_term],
          current_term: installment_data[:current_term] || 0,
          payment_period: installment_data[:payment_period],
          first_payment_date: installment_data[:first_payment_date]
        )

        # Run installment creator
        source_account_id = installment_data[:source_account_id].presence
        Installment::Creator.new(installment, source_account_id: source_account_id).call

        @account.lock_saved_attributes!
      end

      redirect_to account_params[:return_to].presence || @account,
                  notice: t("accounts.create.success", type: "Loan")
    rescue ActiveRecord::RecordInvalid => e
      @account ||= Current.family.accounts.build(ensure_installment_account_params.except(:installment_attributes, :return_to))
      @account.build_installment(installment_params) unless @account.installment
      render :new, status: :unprocessable_entity
    end

    def update_with_installment
      installment_data = installment_params

      ActiveRecord::Base.transaction do
        update_params = ensure_installment_account_params.except(:return_to, :balance, :currency, :installment_attributes, :accountable_attributes)
        unless @account.update(update_params)
          @error_message = @account.errors.full_messages.join(", ")
          render :edit, status: :unprocessable_entity
          return
        end

        installment = @account.installment || @account.build_installment
        installment.update!(installment_data.except(:source_account_id))

        remove_installment_activity(installment)

        source_account_id = installment_data[:source_account_id].presence
        Installment::Creator.new(installment, source_account_id: source_account_id).call

        @account.lock_saved_attributes!
      end

      redirect_back_or_to account_path(@account), notice: t("accounts.update.success", type: "Loan")
    rescue ActiveRecord::RecordInvalid
      @account.build_installment(installment_params) unless @account.installment
      @error_message = @account.errors.full_messages.join(", ")
      render :edit, status: :unprocessable_entity
    end

    def remove_installment_activity(installment)
      entries = @account.entries.joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
                      .where(entryable_type: "Transaction")
                      .where("transactions.extra ->> 'installment_id' = ?", installment.id.to_s)

      entry_ids = entries.pluck(:id)
      transaction_ids = entries.pluck(:entryable_id)

      Entry.where(id: entry_ids).destroy_all
      Transaction.where(id: transaction_ids).destroy_all if transaction_ids.any?
      RecurringTransaction.where(installment_id: installment.id).destroy_all
    end

    def calculate_current_balance_from_params(installment_data)
      cost = installment_data[:installment_cost].to_d
      total = installment_data[:total_term].to_i
      current = (installment_data[:current_term] || 0).to_i

      cost * (total - current)
    end

    def ensure_installment_account_params
      merged_params = account_params.to_h.deep_symbolize_keys
      merged_params[:currency] = merged_params[:currency].presence || Current.family.currency
      merged_params[:accountable_attributes] ||= {}
      merged_params
    end

    def installment_params
      params.require(:account).fetch(:installment_attributes, {}).permit(
        :installment_cost, :total_term, :current_term, :payment_period,
        :first_payment_date, :source_account_id
      )
    rescue ActionController::ParameterMissing
      {}
    end

    def account_params
      params.require(:account).permit(
        :name, :balance, :subtype, :currency, :accountable_type, :return_to,
        :institution_name, :institution_domain, :notes,
        accountable_attributes: self.class.permitted_accountable_attributes,
        installment_attributes: [
          :installment_cost, :total_term, :current_term, :payment_period,
          :first_payment_date, :source_account_id
        ]
      )
    end
end

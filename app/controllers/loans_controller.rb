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

  private

    def create_with_installment
      @account = nil

      ActiveRecord::Base.transaction do
        # Create account with calculated balance
        installment_data = installment_params
        calculated_balance = calculate_current_balance_from_params(installment_data)

        account_attrs = account_params.merge(balance: calculated_balance)
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
      @account ||= Current.family.accounts.build(account_params.except(:installment_attributes, :return_to))
      @account.build_installment(installment_params) unless @account.installment
      render :new, status: :unprocessable_entity
    end

    def calculate_current_balance_from_params(installment_data)
      cost = installment_data[:installment_cost].to_d
      total = installment_data[:total_term].to_i
      current = (installment_data[:current_term] || 0).to_i

      cost * (total - current)
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

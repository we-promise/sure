class InstallmentsController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes(
    :id, :name, :total_installments, :payment_period, :first_payment_date, :installment_cost, :currency, :auto_generate
  )

  def create
    if params[:account]
      account_attrs = params[:account]
      acc_attrs = account_attrs[:accountable_attributes] || {}

      # Sync name and currency from the parent Account form
      acc_attrs[:name] = account_attrs[:name]
      acc_attrs[:currency] = account_attrs[:currency]

      # Auto-calculate balance (Total Liability)
      if acc_attrs[:installment_cost].present? && acc_attrs[:total_installments].present?
        cost = acc_attrs[:installment_cost].to_d
        total = acc_attrs[:total_installments].to_i
        params[:account][:balance] = cost * total
      end

      params[:account][:accountable_attributes] = acc_attrs
    end
    super
  end
end

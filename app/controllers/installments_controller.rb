class InstallmentsController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes(
    :id, :name, :total_installments, :payment_period, :first_payment_date, :installment_cost, :currency, :auto_generate, :family_id
  )

  def create
    if params[:account]
      account_attrs = params[:account]
      acc_attrs = account_attrs[:accountable_attributes] || {}

      # Ensure currency is set for Account (fallback to family currency)
      currency = account_attrs[:currency].presence || Current.family.currency
      params[:account][:currency] = currency

      # Sync name, currency and family to Installment model
      acc_attrs[:name] = account_attrs[:name]
      acc_attrs[:currency] = currency
      acc_attrs[:family_id] = Current.family.id

      # Auto-calculate balance (Total Liability)
      if acc_attrs[:installment_cost].present? && acc_attrs[:total_installments].present?
        cost = acc_attrs[:installment_cost].to_s.gsub(/[^0-9.-]/, "").to_d
        total = acc_attrs[:total_installments].to_i
        params[:account][:balance] = cost * total
      end

      params[:account][:accountable_attributes] = acc_attrs
    end
    super
  end
end

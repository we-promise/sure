class CreditCardsController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes(
    :id,
    :available_credit,
    :minimum_payment,
    :apr,
    :annual_fee,
    :expiration_date
  )

  def update
    update_enable_banking_settings
    super
  end

  private
    def update_enable_banking_settings
      eb_params = params[:account]&.[](:enable_banking)
      return if eb_params.blank?

      provider_account = @account.account_providers.find_by(provider_type: "EnableBankingAccount")&.provider
      return unless provider_account.present?

      provider_account.update!(
        treat_balance_as_available_credit: ActiveModel::Type::Boolean.new.cast(eb_params[:treat_balance_as_available_credit])
      )

      # Re-sync so the balance is reinterpreted right away instead of on the next scheduled sync
      if provider_account.saved_change_to_treat_balance_as_available_credit?
        provider_account.enable_banking_item.sync_later
      end
    end
end

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
    # The update saves more than once (locks), which clears saved_changes, so
    # compare the limit before and after instead.
    @available_credit_before = @account.accountable&.available_credit
    super
    # Only apply provider settings once the account update succeeded (redirect);
    # a failed update renders :edit and must not persist the flag.
    if response.redirect?
      update_enable_banking_settings
      update_lunchflow_settings
      update_simplefin_settings
    end
  end

  private
    def update_enable_banking_settings
      eb_params = params.permit(account: { enable_banking: [ :treat_balance_as_available_credit ] })
        .dig(:account, :enable_banking)
      return if eb_params.blank?

      update_provider_setting(
        provider_type: "EnableBankingAccount",
        attribute: :treat_balance_as_available_credit,
        value: ActiveModel::Type::Boolean.new.cast(eb_params[:treat_balance_as_available_credit])
      ) do |provider_account|
        # Re-sync so the balance is reinterpreted right away instead of on the next scheduled sync
        provider_account.enable_banking_item.sync_later
      end
    end

    # In available-credit mode the debt is read from the card's limit (its
    # Available credit field), so a new limit needs a resync just as toggling
    # the flag does. One sync covers both. A form without the flag keeps it.
    def update_lunchflow_settings
      provider_account = @account.provider_account_for("LunchflowAccount")
      return unless provider_account.present?

      lunchflow_params = params.permit(account: { lunchflow: [ :treat_balance_as_available_credit ] })
        .dig(:account, :lunchflow)
      if lunchflow_params&.key?(:treat_balance_as_available_credit)
        provider_account.update!(
          treat_balance_as_available_credit: ActiveModel::Type::Boolean.new.cast(lunchflow_params[:treat_balance_as_available_credit])
        )
      end

      flag_changed = provider_account.saved_change_to_treat_balance_as_available_credit?
      limit_changed = provider_account.treat_balance_as_available_credit? &&
        @account.accountable.reload.available_credit != @available_credit_before
      provider_account.lunchflow_item.sync_later if flag_changed || limit_changed
    end

    def update_simplefin_settings
      simplefin_params = params.permit(account: { simplefin: [ :balance_sign_override ] })
        .dig(:account, :simplefin)
      return if simplefin_params.blank?

      override = simplefin_params[:balance_sign_override]
      override = nil unless override.in?(%w[credit debt])

      update_provider_setting(
        provider_type: "SimplefinAccount",
        attribute: :balance_sign_override,
        value: override
      ) { |provider_account| provider_account.simplefin_item.sync_later }
    end

    def update_provider_setting(provider_type:, attribute:, value:)
      provider_account = @account.provider_account_for(provider_type)
      return unless provider_account.present?

      provider_account.update!(attribute => value)
      yield provider_account if provider_account.saved_change_to_attribute?(attribute)
    end
end

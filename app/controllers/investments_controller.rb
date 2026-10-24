class InvestmentsController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes :id, :subtype

  def update
    super
    # Only if the account itself saved (we redirected). A failed update renders
    # :edit and shouldn't save the portfolio's settings either.
    update_sharesight_settings if response.redirect?
  end

  private

    def update_sharesight_settings
      sharesight_account = @account.provider_account_for("SharesightAccount")
      return unless sharesight_account

      settings = params.permit(account: { sharesight: SharesightAccount::SETTINGS_ATTRIBUTES }).dig(:account, :sharesight)
      return if settings.blank?

      sharesight_account.assign_cash_settings(settings)
      if other_accounts_writable?(sharesight_account) && sharesight_account.save
        sharesight_account.sharesight_item.sync_later if sharesight_account.cash_settings_changed?
      else
        flash.delete(:notice)
        flash[:alert] = sharesight_account.errors.full_messages.to_sentence.presence || t("accounts.not_authorized")
      end
    end

    # You have to be able to edit the settlement, dividend and funding accounts.
    def other_accounts_writable?(sharesight_account)
      ids = [ sharesight_account.settlement_account_id, sharesight_account.dividend_account_id, sharesight_account.funding_account_id ].compact.uniq
      ids.empty? || Current.family.accounts.writable_by(Current.user).where(id: ids).count == ids.size
    end
end

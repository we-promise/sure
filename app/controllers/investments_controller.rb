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
      if new_accounts_writable?(sharesight_account) && sharesight_account.save
        sharesight_account.sharesight_item.sync_later if sharesight_account.cash_settings_changed?
      else
        flash.delete(:notice)
        flash[:alert] = sharesight_account.errors.full_messages.to_sentence.presence || t("accounts.not_authorized")
      end
    end

    # You have to be able to edit any settlement, dividend or funding account you
    # newly choose. One that's already saved can stay even if you can't edit it.
    def new_accounts_writable?(sharesight_account)
      ids = %w[settlement_account_id dividend_account_id funding_account_id].filter_map do |attribute|
        sharesight_account.public_send(attribute) if sharesight_account.attribute_changed?(attribute)
      end.uniq
      ids.empty? || Current.family.accounts.writable_by(Current.user).where(id: ids).count == ids.size
    end
end

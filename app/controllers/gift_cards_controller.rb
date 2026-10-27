class GiftCardsController < ApplicationController
  include AccountableResource

  before_action :require_preview_features!, only: %i[new create]
  before_action :set_account, only: :credentials

  permitted_accountable_attributes(:id, :card_format, :expires_on, :face_value, :card_number, :pin, :redeem_url)

  # The overview shows a card's PIN masked. It is sent only on request, so it
  # is not part of the account page, and not cached.
  def credentials
    return head :not_found unless @account.gift_card&.credentials_visible_to?(Current.user)

    response.headers["Cache-Control"] = "no-store"
    render partial: "gift_cards/credentials", locals: { account: @account, revealed: params[:reveal].present? }
  end

  private
    # A card's initial amount is what it was worth when received: the entered
    # balance, unless the card had already been partly spent. It is stored as
    # `face_value`, not `initial_balance`, so the ledger opens at the entered
    # balance: an `initial_balance` would make `create_and_sync` anchor today's
    # balance too, and that anchor would override spending recorded today.
    def submitted_account_attributes
      attributes = super.to_h
      accountable_attributes = attributes.fetch(:accountable_attributes, {})
      accountable_attributes[:face_value] = attributes[:balance] if accountable_attributes[:face_value].blank?
      accountable_attributes[:face_value_currency] = attributes[:currency].presence || Current.family.currency
      attributes.merge(accountable_attributes: accountable_attributes)
    end

    # The form asks when the card was received. Its value is anchored at the
    # end of the day before, so spending on the day it was received still
    # lowers the balance (a valuation sets that day's closing balance).
    def opening_balance_date
      super.prev_day
    end
end

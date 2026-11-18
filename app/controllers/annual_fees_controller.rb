# Every credit card's annual fee and when it next renews.
class AnnualFeesController < ApplicationController
  def index
    @summary = AnnualFeeSummary.new(cards, currency: Current.family.currency, as_of: Date.current)
  end

  # Looks for each card's fee in its own transactions and fills in what's missing.
  def detect
    updated = cards.count do |card|
      next false unless card.account.permission_for(Current.user).in?([ :owner, :full_control ])

      before = card.attributes.slice("annual_fee", "annual_fee_month", "annual_fee_day")
      CreditCard::AnnualFeeDetector.new(card).apply!
      before != card.reload.attributes.slice("annual_fee", "annual_fee_month", "annual_fee_day")
    end
    redirect_to annual_fees_path, notice: t(".updated", count: updated)
  end

  private
    def cards
      @cards_scope ||= CreditCard.joins(:account)
        .merge(Current.user.accessible_accounts.visible)
        .includes(:account)
        .to_a
    end
end

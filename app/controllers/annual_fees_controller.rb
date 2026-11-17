# Every credit card's annual fee and when it next renews.
class AnnualFeesController < ApplicationController
  def index
    @as_of = Date.current
    # Cards with a renewal date first, soonest first; the rest by name.
    @cards = cards.sort_by do |card|
      date = card.next_annual_fee_date(as_of: @as_of)
      [ date ? 0 : 1, date || Date.new(9999, 12, 31), card.account.name ]
    end
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

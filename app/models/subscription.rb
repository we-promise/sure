class Subscription < ApplicationRecord
  TRIAL_DAYS = 45

  belongs_to :family

  # https://docs.stripe.com/api/subscriptions/object
  enum :status, {
    incomplete: "incomplete",
    incomplete_expired: "incomplete_expired",
    trialing: "trialing", # We use this, but "offline" (no through Stripe's interface)
    active: "active",
    past_due: "past_due",
    canceled: "canceled",
    unpaid: "unpaid",
    paused: "paused"
  }

  validates :stripe_id, presence: true, if: :active?
  validates :trial_ends_at, presence: true, if: :trialing?
  validates :family_id, uniqueness: true

  class << self
    def new_trial_ends_at
      TRIAL_DAYS.days.from_now
    end
  end

  def name
    case interval
    when "month"
      "Monthly Contribution"
    when "year"
      "Annual Contribution"
    else
      "Open demo"
    end
  end

  def pending_cancellation?
    active? && cancel_at_period_end?
  end
end

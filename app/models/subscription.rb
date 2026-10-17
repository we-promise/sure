class Subscription < ApplicationRecord
  TRIAL_DAYS = 45

  # Sentinel Stripe ID used by the demo data generator. This is not a real
  # Stripe object; any code path that would call the Stripe API must call
  # `synthetic?` first to skip demo subscriptions.
  DEMO_STRIPE_ID = "sub_demo_123"

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

  # Returns true when this subscription is a demo/synthetic object with no
  # backing Stripe record.  Callers that would otherwise hit the Stripe API
  # (e.g. the before_destroy cancel callback) should guard with this predicate.
  def synthetic?
    stripe_id == DEMO_STRIPE_ID
  end
end

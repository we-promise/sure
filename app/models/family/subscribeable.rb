module Family::Subscribeable
  extend ActiveSupport::Concern

  CLEANUP_GRACE_PERIOD = 14.days
  ARCHIVE_TRANSACTION_THRESHOLD = 12
  ARCHIVE_RECENT_ACTIVITY_WINDOW = 14.days

  included do
    has_one :subscription, dependent: :destroy

    scope :inactive_trial_for_cleanup, -> {
      cutoff_with_sub = CLEANUP_GRACE_PERIOD.ago
      cutoff_without_sub = (Subscription::TRIAL_DAYS.days + CLEANUP_GRACE_PERIOD).ago

      expired_trial = left_joins(:subscription)
        .where(subscriptions: { status: [ "paused", "trialing" ] })
        .where(subscriptions: { trial_ends_at: ...cutoff_with_sub })

      no_subscription = left_joins(:subscription)
        .where(subscriptions: { id: nil })
        .where(families: { created_at: ...cutoff_without_sub })

      where(id: expired_trial).or(where(id: no_subscription))
    }
  end

  def payment_email
    primary_admin = users.admin.order(:created_at).first || users.super_admin.order(:created_at).first

    unless primary_admin.present?
      raise "No primary admin found for family #{id}.  This is an invalid data state and should never occur."
    end

    primary_admin.email
  end

  def upgrade_required?
    return false if self_hoster?
    return false if subscription&.active? || subscription&.trialing?

    true
  end

  def can_start_trial?
    subscription&.trial_ends_at.blank?
  end

  def start_trial_subscription!
    create_subscription!(
      status: "trialing",
      trial_ends_at: Subscription.new_trial_ends_at
    )
  end

  def trialing?
    subscription&.trialing? && days_left_in_trial.positive?
  end

  def has_active_subscription?
    subscription&.active?
  end

  def can_manage_subscription?
    stripe_customer_id.present?
  end

  def needs_subscription?
    subscription.nil? && !self_hoster?
  end

  def next_payment_date
    subscription&.current_period_ends_at
  end

  def subscription_pending_cancellation?
    subscription&.pending_cancellation?
  end

  def start_subscription!(stripe_subscription_id)
    if subscription.present?
      subscription.update!(status: "active", stripe_id: stripe_subscription_id)
    else
      create_subscription!(status: "active", stripe_id: stripe_subscription_id)
    end
  end

  def days_left_in_trial
    return -1 unless subscription.present?
    ((subscription.trial_ends_at - Time.current).to_i / 86400) + 1
  end

  def percentage_of_trial_remaining
    return 0 unless subscription.present?
    (days_left_in_trial.to_f / Subscription::TRIAL_DAYS) * 100
  end

  def percentage_of_trial_completed
    return 0 unless subscription.present?
    (1 - days_left_in_trial.to_f / Subscription::TRIAL_DAYS) * 100
  end

  def sync_trial_status!
    if subscription&.status == "trialing" && days_left_in_trial < 0
      subscription.update!(status: "paused")
    end
  end

  def requires_data_archive?
    return false unless transactions.count > ARCHIVE_TRANSACTION_THRESHOLD

    trial_end = subscription&.trial_ends_at || (created_at + Subscription::TRIAL_DAYS.days)
    recent_window_start = trial_end - ARCHIVE_RECENT_ACTIVITY_WINDOW

    entries.where(date: recent_window_start..trial_end).exists?
  end
end

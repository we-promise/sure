# frozen_string_literal: true

# A retained-data snapshot for the two project-operated installations. It does
# not contact Stripe, run cleanup, enqueue jobs, or reconstruct deleted history.
class HostedUsage
  HOSTS = %w[app.sure.am demo.sure.am].freeze
  ROW_LIMIT = 100

  Trial = Data.define(
    :family_id, :family_name, :recorded_at, :trial_ends_at, :status,
    :member_count, :retained_sessions_count, :sessions_created_in_window_count,
    :latest_session_created_at, :cleanup_eligible, :synthetic_demo
  )
  CleanupCandidate = Data.define(
    :family_id, :family_name, :status, :trial_ends_at, :reason, :synthetic_demo
  )

  # Request headers alone cannot enable this feature on another installation.
  # Do not accept URLs, ports, suffix matches, forwarded values, or wildcards
  # from APP_DOMAIN: it must be the exact trusted deployment hostname.
  def self.available?(request_host:)
    configured_host = ENV["APP_DOMAIN"]
    HOSTS.include?(configured_host) && request_host == configured_host
  end

  attr_reader :as_of, :window_start, :expiring_window_end

  def initialize
    @as_of = Time.current
    @window_start = 30.days.ago(as_of)
    @expiring_window_end = 7.days.from_now(as_of)
  end

  def row_limit
    ROW_LIMIT
  end

  def cleanup_enabled?
    Rails.application.config.app_mode.managed?
  end

  def summary
    snapshot.fetch(:summary)
  end

  def trials
    snapshot.fetch(:trials)
  end

  def cleanup_candidates
    snapshot.fetch(:cleanup_candidates)
  end

  def supporter_status_counts
    snapshot.fetch(:supporter_status_counts)
  end

  private
    def snapshot
      @snapshot ||= ActiveRecord::Base.while_preventing_writes { build_snapshot }
    end

    def build_snapshot
      # Conversion updates the same row. Keep converted trials in this cohort,
      # but label created_at as the retained record date, not a paid-start date
      # or a durable historical trial-start event.
      trial_scope = Subscription.joins(:family)
        .where.not(trial_ends_at: nil)
        .where(created_at: window_start..as_of)
      cleanup_scope = Family.inactive_trial_for_cleanup
      supporter_scope = Subscription.joins(:family)
        .where("subscriptions.stripe_id ~ ?", "^sub_[A-Za-z0-9]+$")
        .where("families.stripe_customer_id ~ ?", "^cus_[A-Za-z0-9]+$")

      {
        summary: {
          trial_households_count: trial_scope.count,
          trial_members_count: User.where(family_id: trial_scope.select(:family_id)).count,
          cleanup_eligible_count: cleanup_scope.count,
          active_supporter_households_count: supporter_scope.where(status: :active).distinct.count(:family_id),
          supporter_subscription_count: supporter_scope.count,
          trials_expiring_soon_count: Subscription.where(status: :trialing)
            .where(trial_ends_at: as_of..expiring_window_end).count
        },
        trials: trial_rows(trial_scope, cleanup_scope),
        cleanup_candidates: cleanup_rows(cleanup_scope),
        supporter_status_counts: status_counts(supporter_scope)
      }
    end

    def status_counts(scope)
      counts = Subscription.statuses.keys.index_with(0)
      scope.group(:status).count.each do |status, count|
        key = counts.key?(status) ? status : "unknown"
        counts[key] = counts.fetch(key, 0) + count
      end
      counts
    end

    def trial_rows(scope, cleanup_scope)
      rows = scope.order(created_at: :desc, id: :desc).limit(row_limit).pluck(
        :family_id, "families.name", "subscriptions.created_at",
        :trial_ends_at, :status, :stripe_id
      )
      family_ids = rows.map(&:first)
      return [] if family_ids.empty?

      members = User.where(family_id: family_ids).group(:family_id).count
      # Match authentication eligibility for enabled users, but do not claim
      # these retained login credentials represent people currently online.
      sessions = Session.joins(:user).where(users: { family_id: family_ids, active: true })
      retained = sessions.group("users.family_id").count
      recent = sessions.where(created_at: window_start..as_of).group("users.family_id").count
      latest = sessions.group("users.family_id").maximum("sessions.created_at")
      eligible = cleanup_scope.where(id: family_ids).pluck(:id).to_set

      rows.map do |family_id, family_name, created_at, trial_ends_at, status, stripe_id|
        Trial.new(
          family_id:, family_name:, recorded_at: created_at, trial_ends_at:, status:,
          member_count: members.fetch(family_id, 0),
          retained_sessions_count: retained.fetch(family_id, 0),
          sessions_created_in_window_count: recent.fetch(family_id, 0),
          latest_session_created_at: latest[family_id],
          cleanup_eligible: eligible.include?(family_id),
          synthetic_demo: stripe_id == Subscription::DEMO_STRIPE_ID
        )
      end
    end

    def cleanup_rows(scope)
      scope.left_joins(:subscription).order(created_at: :asc, id: :asc).limit(row_limit).pluck(
        "families.id", "families.name", "subscriptions.id",
        "subscriptions.status", "subscriptions.trial_ends_at", "subscriptions.stripe_id"
      ).map do |family_id, family_name, subscription_id, status, trial_ends_at, stripe_id|
        CleanupCandidate.new(
          family_id:, family_name:, status:, trial_ends_at:,
          reason: subscription_id ? :expired_trial_grace_elapsed : :no_subscription_grace_elapsed,
          synthetic_demo: stripe_id == Subscription::DEMO_STRIPE_ID
        )
      end
    end
end

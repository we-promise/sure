class SendInsightDigestJob < ApplicationJob
  queue_as :scheduled

  WEEK_TTL = 7.days

  def perform(family_id: nil)
    scope = family_id ? Family.where(id: family_id) : Family.all
    week_key = Date.current.cweek
    week_year = Date.current.cwyear

    scope.find_each do |family|
      insights = family.insights.status_active.by_priority.limit(5).to_a
      next if insights.empty?

      family.users.find_each do |user|
        next if user.insight_digest_disabled?
        next if user.email.blank?
        next unless claim_send_slot(user, week_year, week_key)

        InsightDigestMailer.with(user: user, insights: insights).weekly.deliver_later
      end
    end
  end

  private
    # Atomic per-user-per-ISO-week guard so retries or overlapping cron runs
    # don't double-send. Backed by Rails.cache; `unless_exist: true` returns
    # false when the key already exists (atomic on Redis / Solid Cache).
    def claim_send_slot(user, week_year, week_key)
      Rails.cache.write(
        "insight_digest:#{user.id}:#{week_year}-W#{week_key}",
        true,
        unless_exist: true,
        expires_in: WEEK_TTL
      )
    end
end

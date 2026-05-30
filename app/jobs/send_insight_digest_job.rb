class SendInsightDigestJob < ApplicationJob
  queue_as :scheduled

  # TODO: add a per-user / per-ISO-week idempotency guard (durable marker
  # or atomic cache claim) before enqueueing the mailer so cron retries
  # or overlapping runs can't double-send. Tracked for a follow-up PR.
  def perform(family_id: nil)
    scope = family_id ? Family.where(id: family_id) : Family.all

    scope.find_each do |family|
      insights = family.insights.status_active.by_priority.limit(5).to_a
      next if insights.empty?

      family.users.find_each do |user|
        next if user.insight_digest_disabled?
        next if user.email.blank?

        InsightDigestMailer.with(user: user, insights: insights).weekly.deliver_later
      end
    end
  end
end

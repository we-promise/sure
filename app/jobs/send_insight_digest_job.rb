class SendInsightDigestJob < ApplicationJob
  queue_as :scheduled

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

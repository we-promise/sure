class GenerateInsightsJob < ApplicationJob
  queue_as :scheduled

  # When called from cron (no family_id), iterates all families with insights enabled.
  # Can also be triggered on-demand for a single family (e.g., from the UI "Refresh" button).
  def perform(family_id: nil)
    return unless Setting.insights_enabled

    if family_id
      family = Family.find_by(id: family_id)
      generate_for_family(family) if family
    else
      Family.find_each do |family|
        generate_for_family(family)
      end
    end
  end

  private
    def generate_for_family(family)
      generated = Insight::GeneratorRegistry.generate_for(family)
      upsert_insights(family, generated)
      Rails.logger.info("[GenerateInsightsJob] Upserted #{generated.size} insights for family #{family.id}")
    rescue => e
      Rails.logger.error("[GenerateInsightsJob] Failed for family #{family.id}: #{e.message}")
    end

    def upsert_insights(family, generated_insights)
      generated_insights.each do |gi|
        upsert_insight(family, gi)
      end
    end

    def upsert_insight(family, gi, attempts: 0)
      existing = family.insights.find_by(dedup_key: gi.dedup_key)

      if existing
        # Reactivate only if the underlying numbers changed materially
        numbers_changed = existing.metadata != gi.metadata
        new_status = (numbers_changed && existing.dismissed?) ? "active" : existing.status

        existing.update!(
          title:        gi.title,
          body:         gi.body,
          metadata:     gi.metadata,
          priority:     gi.priority,
          status:       new_status,
          generated_at: Time.current,
          period_start: gi.period_start,
          period_end:   gi.period_end
        )
      else
        family.insights.create!(
          insight_type: gi.insight_type,
          priority:     gi.priority,
          status:       "active",
          title:        gi.title,
          body:         gi.body,
          metadata:     gi.metadata,
          currency:     gi.currency || family.currency,
          period_start: gi.period_start,
          period_end:   gi.period_end,
          dedup_key:    gi.dedup_key,
          generated_at: Time.current
        )
      end
    rescue ActiveRecord::RecordNotUnique
      raise if attempts >= 2
      upsert_insight(family, gi, attempts: attempts + 1)
    end
end

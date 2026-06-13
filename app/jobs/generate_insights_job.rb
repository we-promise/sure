class GenerateInsightsJob < ApplicationJob
  queue_as :scheduled

  def perform(family_id: nil)
    if family_id
      family = Family.find_by(id: family_id)
      generate_for(family) if family
    else
      # Fan out so one slow LLM call can't block other families and so retries
      # are scoped to a single family.
      Family.find_each { |family| self.class.perform_later(family_id: family.id) }
    end
  end

  private
    def generate_for(family)
      with_advisory_lock(family.id) do
        generated = Insight::GeneratorRegistry.new(family).generate_all
        upsert_insights(family, generated)
      end
    rescue => e
      Rails.logger.error("GenerateInsightsJob failed for family #{family.id}: #{e.message}")
    end

    def upsert_insights(family, generated_insights)
      generated_insights.each do |gi|
        existing = family.insights.find_by(dedup_key: gi.dedup_key)

        if existing
          numbers_changed = existing.metadata != gi.metadata.deep_stringify_keys
          # Only reactivate non-dismissed insights so a dismiss isn't undone
          # by an upsert when the underlying numbers shift the next day.
          reactivate = numbers_changed && !existing.status_dismissed?
          existing.update!(
            title: gi.title,
            body: gi.body,
            metadata: gi.metadata,
            priority: gi.priority,
            currency: gi.currency,
            period_start: gi.period_start,
            period_end: gi.period_end,
            generated_at: Time.current,
            status: reactivate ? "active" : existing.status
          )
        else
          family.insights.create!(
            **gi.to_h,
            status: "active",
            generated_at: Time.current
          )
        end
      end
    end

    def with_advisory_lock(family_id)
      lock_key = advisory_lock_key(family_id)
      acquired = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_lock(?)", lock_key ])
      )

      return unless acquired

      begin
        yield
      ensure
        ActiveRecord::Base.connection.execute(
          ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_unlock(?)", lock_key ])
        )
      end
    end

    def advisory_lock_key(family_id)
      Digest::MD5.hexdigest("generate_insights:#{family_id}").to_i(16) % (2**31)
    end
end

class GenerateInsightsJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  # Without args (cron): fans out one job per family.
  # With family_id: generates and upserts that family's insights.
  def perform(family_id: nil)
    if family_id.present?
      generate_for_family(family_id)
    else
      fan_out
    end
  end

  private
    def fan_out
      Family.find_each do |family|
        GenerateInsightsJob.perform_later(family_id: family.id)
      rescue => e
        Rails.logger.error("Failed to enqueue insight generation for family #{family.id}: #{e.message}")
      end
    end

    def generate_for_family(family_id)
      family = Family.find_by(id: family_id)
      return unless family
      return if family.accounts.none?

      with_advisory_lock(family_id) do
        I18n.with_locale(family.locale) do
          result = Insight::GeneratorRegistry.new(family).generate_all
          upsert_insights(family, result.insights)
          expire_stale_insights(family, result)
        end
      end
    end

    # A visible insight whose generator ran successfully but did not re-emit
    # its dedup_key has had its condition clear — hide it. Types whose
    # generator crashed are left untouched so a transient failure can't wipe
    # out healthy insights.
    def expire_stale_insights(family, result)
      family.insights
        .visible
        .where(insight_type: result.succeeded_types)
        .where.not(dedup_key: result.insights.map(&:dedup_key))
        .update_all(status: "expired", updated_at: Time.current)
    end

    def upsert_insights(family, generated_insights)
      writer = Insight::BodyWriter.new(family)

      generated_insights.each do |generated|
        metadata = normalize_metadata(generated.metadata)
        existing = family.insights.find_by(dedup_key: generated.dedup_key)

        if existing.nil?
          family.insights.create!(
            insight_type: generated.insight_type,
            priority: generated.priority,
            status: "active",
            title: generated.title,
            body: writer.write(generated),
            metadata: metadata,
            currency: generated.currency,
            period_start: generated.period_start,
            period_end: generated.period_end,
            generated_at: Time.current,
            dedup_key: generated.dedup_key
          )
        elsif existing.metadata != metadata
          # The numbers changed materially: refresh the prose and resurface the
          # insight even if the user had read or dismissed the stale version.
          existing.update!(
            priority: generated.priority,
            status: "active",
            title: generated.title,
            body: writer.write(generated),
            metadata: metadata,
            period_start: generated.period_start,
            period_end: generated.period_end,
            generated_at: Time.current
          )
        elsif existing.expired?
          # The condition cleared earlier and has now returned with the same
          # numbers. Expiry was the system's doing, not the user's, so the
          # insight resurfaces; the body is still accurate, so no rewrite.
          existing.update!(status: "active", generated_at: Time.current)
        else
          # Same signal, same numbers: don't rewrite the body (avoids an LLM
          # call) and don't undo the user's read/dismissed state.
          existing.update!(generated_at: Time.current)
        end
      rescue ActiveRecord::RecordNotUnique
        # A concurrent run created the same dedup_key first; it owns this row.
        next
      rescue => e
        Rails.logger.error("Failed to upsert insight #{generated.dedup_key} for family #{family.id}: #{e.message}")
      end
    end

    # GeneratedInsight metadata may hold symbols, dates, or BigDecimals; the
    # persisted jsonb column round-trips everything to JSON primitives. Compare
    # like with like or every nightly run would look like a material change.
    def normalize_metadata(metadata)
      JSON.parse(metadata.to_json)
    end

    def with_advisory_lock(family_id)
      lock_key = advisory_lock_key(family_id)
      acquired = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_lock(?)", lock_key ])
      )

      unless acquired
        Rails.logger.warn("Skipped insight generation for family #{family_id}: advisory lock unavailable")
        return
      end

      begin
        yield
      ensure
        ActiveRecord::Base.connection.execute(
          ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_unlock(?)", lock_key ])
        )
      end
    end

    def advisory_lock_key(family_id)
      # Use (nearly) the full signed-bigint space pg_try_advisory_lock accepts
      # to keep the collision odds between families negligible.
      Digest::MD5.hexdigest("generate_insights:#{family_id}").to_i(16) % (2**62)
    end
end

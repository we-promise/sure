class Assistant::Function::GetInsights < Assistant::Function
  DEFAULT_LIMIT = 10
  MAX_LIMIT = 50

  class << self
    def name
      "get_insights"
    end

    def description
      <<~INSTRUCTIONS
        Reads the family's proactive insights feed: typed observations like spending
        anomalies, cash-flow warnings, subscription audits, savings-rate changes and
        net-worth milestones, generated nightly with pre-computed numbers in
        `metadata`.

        Use this to answer "anything I should know about my finances?" or to ground
        analysis in signals the app has already detected. Read-only: it does not
        mark insights read or acknowledged.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [],
      properties: {
        insight_type: {
          type: "string",
          enum: Insight::TYPES,
          description: "Only return insights of this type"
        },
        include_acknowledged: {
          type: "boolean",
          description: "Include insights the user has already acknowledged (defaults to false)"
        },
        limit: {
          type: "integer",
          minimum: 1,
          maximum: MAX_LIMIT,
          description: "Max results (defaults to #{DEFAULT_LIMIT})"
        }
      }
    )
  end

  # Insights are family-scoped by design (the nightly generator runs per
  # family, not per user), so there is no per-account visibility filter here.
  # That matches the web feed exactly: InsightsController serves
  # Current.family.insights to every member, so this tool exposes nothing the
  # /insights page does not already show the same user.
  def call(params = {})
    scope = params["include_acknowledged"] ? family.insights.where.not(status: :expired) : family.insights.visible
    scope = scope.where(insight_type: params["insight_type"]) if params["insight_type"].present?

    limit = params["limit"].present? ? params["limit"].to_i.clamp(1, MAX_LIMIT) : DEFAULT_LIMIT

    {
      insights: scope.ordered.limit(limit).map { |insight|
        {
          id: insight.id,
          type: insight.insight_type,
          title: insight.title,
          body: insight.body,
          priority: insight.priority,
          status: insight.status,
          period_start: insight.period_start,
          period_end: insight.period_end,
          generated_at: insight.generated_at.iso8601,
          metadata: insight.metadata
        }.compact
      }
    }
  end
end

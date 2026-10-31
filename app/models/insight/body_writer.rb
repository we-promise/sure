class Insight::BodyWriter
  def write(generated_insight)
    I18n.t(
      "insights.templates.#{generated_insight.template_key}",
      **generated_insight.facts.symbolize_keys
    )
  end
end

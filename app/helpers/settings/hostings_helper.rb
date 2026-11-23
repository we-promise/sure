module Settings::HostingsHelper
  # The Self-Hosting page renders what a call would resolve to, from ENV and
  # Setting, so the views read these instead of reaching into the config classes.

  def effective_categorization_provider = Ai::LegacyEnvConfig.categorization_provider

  def jev_configured? = Ai::LegacyEnvConfig::Jev.configured?

  def jev_endpoint = Ai::Instrumentation::Redactor.url(Ai::LegacyEnvConfig::Jev.effective_endpoint)

  def jev_model = Ai::LegacyEnvConfig::Jev.effective_model

  def jev_effective_host = Ai::LegacyEnvConfig::Jev.effective_host

  def jev_effective_proxied? = Ai::LegacyEnvConfig::Jev.effective_proxied?

  # Why the configured Jev endpoint can't be used, or nil — for the warning next
  # to the settings when an ENV value is bad, which otherwise fails quietly.
  def jev_unreachable_reason = Ai::LegacyEnvConfig::Jev.unreachable_reason(Ai::LegacyEnvConfig::Jev.effective_endpoint)

  # The shadow panel's raw materials: how many the routes disagree, the agreement
  # rate, the five most recent disagreements and their category names by id
  # (Ai::Comparison#category_name).
  def categorization_shadow_summary(family)
    comparisons = family.categorization_comparisons
    disagreements = comparisons.disagreements.order(created_at: :desc).limit(5).to_a
    sampled, agreement = comparisons.sample_and_agreement
    {
      sampled:,
      agreement:,
      disagreements:,
      names: Ai::Comparison.category_names(disagreements, family)
    }
  end
end

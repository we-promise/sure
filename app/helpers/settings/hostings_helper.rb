module Settings::HostingsHelper
  # The Self-Hosting page renders what a call would resolve to, from ENV and
  # Setting, so the views read these instead of reaching into the config classes.

  def effective_categorization_provider = Ai::LegacyEnvConfig.categorization_provider

  def jev_configured? = Ai::LegacyEnvConfig::Jev.configured?

  def jev_endpoint = Ai::LegacyEnvConfig::Jev.redacted_endpoint(Ai::LegacyEnvConfig::Jev.effective_endpoint)

  def jev_model = Ai::LegacyEnvConfig::Jev.effective_model

  def jev_effective_host = Ai::LegacyEnvConfig::Jev.effective_host

  def jev_effective_proxied? = Ai::LegacyEnvConfig::Jev.effective_proxied?

  # The shadow panel's raw materials: how many the routes disagree, the agreement
  # rate and the five most recent disagreements with their category names resolved.
  def categorization_shadow_summary(family)
    comparisons = family.categorization_comparisons
    {
      sampled: comparisons.count,
      agreement: comparisons.agreement_rate,
      disagreements: Ai::Comparison.with_display_names(
        comparisons.disagreements.order(created_at: :desc).limit(5).to_a, family
      )
    }
  end
end

module OnboardingsHelper
  def onboarding_starting_tools
    User::STARTING_TOOLS.map { |value| [ value, t("onboardings.tools.tools.#{value}") ] }
  end

  def onboarding_provider
    provider = Current.family.ai_configuration&.provider.presence || Setting.llm_provider
    provider.in?(OnboardingAiConfiguration::PROVIDERS) ? provider : "openai"
  end

  def onboarding_openrouter_model
    configuration = Current.family.ai_configuration
    configuration.model if configuration&.provider == "openrouter"
  end

  def onboarding_provider_options
    OnboardingAiConfiguration::PROVIDERS.to_h do |provider|
      label = t("onboardings.tools.provider_setup.providers.#{provider}")
      [ provider, {
        label: t("onboardings.tools.provider_setup.key_label", provider: label),
        placeholder: t("onboardings.tools.provider_setup.key_placeholder", provider: label)
      } ]
    end
  end

  def onboarding_ai_modes
    %w[none builtin external]
  end
end

module OnboardingsHelper
  def onboarding_starting_tools
    User::STARTING_TOOLS.map { |value| [ value, t("onboardings.tools.tools.#{value}") ] }
  end

  def onboarding_provider
    Setting.llm_provider.in?(OnboardingAiConfiguration::PROVIDERS) ? Setting.llm_provider : "openai"
  end

  def onboarding_provider_options
    OnboardingAiConfiguration::PROVIDERS.to_h do |provider|
      label = t("onboardings.tools.provider_setup.providers.#{provider}")
      [ provider, {
        label: t("onboardings.tools.provider_setup.key_label", provider: label),
        placeholder: t("onboardings.tools.provider_setup.key_placeholder", provider: label),
        locked: OnboardingAiConfiguration.configuration_locked?(provider)
      } ]
    end
  end

  def onboarding_ai_modes
    %w[none builtin external]
  end
end

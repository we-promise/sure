require "shellwords"

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
      key_name = t("onboardings.tools.provider_setup.key_names.#{provider}", default: label)
      [ provider, {
        label: t("onboardings.tools.provider_setup.key_label", provider: key_name),
        placeholder: t("onboardings.tools.provider_setup.key_placeholder", provider: key_name)
      } ]
    end
  end

  def onboarding_ai_modes
    %w[none builtin external]
  end

  def onboarding_agent_instructions
    instance_url = root_url.delete_suffix("/")

    t("onboardings.tools.agent_instructions",
      product_name: product_name,
      instance_url: instance_url,
      cli_instance_url: Shellwords.escape(instance_url),
      mcp_url: mcp_url,
      mcp_settings_url: settings_mcp_url)
  end
end

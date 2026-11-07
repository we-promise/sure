module OnboardingsHelper
  def onboarding_starting_tools
    User::STARTING_TOOLS.map { |value| [ value, t("onboardings.tools.tools.#{value}") ] }
  end

  def onboarding_ai_modes
    %w[none builtin external]
  end
end

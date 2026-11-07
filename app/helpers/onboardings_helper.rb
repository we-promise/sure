module OnboardingsHelper
  def onboarding_starting_tools
    User::STARTING_TOOLS.map { |value| [ value, t("onboardings.goals.tools.#{value}") ] }
  end

  def onboarding_ai_modes
    %w[none builtin external]
  end
end

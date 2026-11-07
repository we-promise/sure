class AddInitialOnboardingAiModeToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :initial_onboarding_ai_mode, :string
    add_check_constraint :families,
                         "initial_onboarding_ai_mode IN ('none', 'builtin', 'external')",
                         name: "chk_families_initial_onboarding_ai_mode"
  end
end

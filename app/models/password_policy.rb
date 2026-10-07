# The password rules shared by sign-up, the admin reset, the API signup and the
# password change/reset. password_validator_controller.js mirrors them for the
# live checklist on the sign-up form, so change both together.
class PasswordPolicy
  MIN_LENGTH = 8
  SPECIAL_CHARACTERS = /[!@#$%^&*(),.?":{}|<>]/

  # Returns the unmet rules as symbols, in display order:
  # :too_short, :missing_case, :missing_number, :missing_special.
  def self.unmet_requirements(password)
    password = password.to_s
    unmet = []
    unmet << :too_short if password.length < MIN_LENGTH
    unmet << :missing_case unless password.match?(/[A-Z]/) && password.match?(/[a-z]/)
    unmet << :missing_number unless password.match?(/\d/)
    unmet << :missing_special unless password.match?(SPECIAL_CHARACTERS)
    unmet
  end
end

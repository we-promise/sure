# The password rules shared by sign-up, the admin reset, the API signup and the
# password change/reset. password_validator_controller.js mirrors them for the
# live checklist on the sign-up form, so change both together. The byte limit
# has no checklist row: the sign-up field's maxlength caps characters, and
# accented letters or emoji that push past 72 bytes get the server's message.
class PasswordPolicy
  MIN_LENGTH = 8
  # bcrypt ignores everything after byte 72, so a longer password would be
  # checked only up to there. has_secure_password enforces this unless its
  # validations are off, as they are on User.
  MAX_BYTES = ActiveModel::SecurePassword::MAX_PASSWORD_LENGTH_ALLOWED
  SPECIAL_CHARACTERS = /[!@#$%^&*(),.?":{}|<>]/

  # Returns the unmet rules as symbols, in display order:
  # :too_short, :too_long, :missing_case, :missing_number, :missing_special.
  def self.unmet_requirements(password)
    password = password.to_s
    unmet = []
    unmet << :too_short if password.length < MIN_LENGTH
    unmet << :too_long if too_long?(password)
    unmet << :missing_case unless password.match?(/[A-Z]/) && password.match?(/[a-z]/)
    unmet << :missing_number unless password.match?(/\d/)
    unmet << :missing_special unless password.match?(SPECIAL_CHARACTERS)
    unmet
  end

  def self.too_long?(password)
    password.to_s.bytesize > MAX_BYTES
  end
end

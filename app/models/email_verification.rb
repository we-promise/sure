# Single switch for whether this instance enforces email verification before
# serving financial data. Backed by the existing require_email_confirmation
# setting, so it is toggleable from Settings -> Hosting (self-hosted) or via the
# REQUIRE_EMAIL_CONFIRMATION environment variable in any mode.
#
# When disabled, nothing gates on User#email_verified? — including accounts that
# were never verified — so the feature can be turned off cleanly rather than
# stranding existing users behind a per-account flag.
class EmailVerification
  def self.enforced?
    Setting.require_email_confirmation
  end
end

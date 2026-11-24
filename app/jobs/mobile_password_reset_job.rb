class MobilePasswordResetJob < ApplicationJob
  # Email is this job's only argument; keep it out of the job logs.
  self.log_arguments = false

  # Does the account lookup and delivery decision off the request thread, so the
  # controller enqueues identical work for every request and leaks no timing
  # signal about whether an account exists.
  def perform(email)
    user = User.find_by_email_with_legacy_fallback(email)
    return unless user && !user.sso_only? && AuthConfig.password_features_enabled?

    PasswordMailer.with(user: user).mobile_password_reset.deliver_later
  end
end

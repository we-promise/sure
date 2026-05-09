module Provider::Auth
  ConsentExpiredError = Class.new(StandardError)
  TokenRevokedError   = Class.new(StandardError)
  ReauthRequiredError = Class.new(StandardError)
  # Network failures and upstream 5xx — safe to retry, not user-actionable.
  TransientError      = Class.new(StandardError)
end

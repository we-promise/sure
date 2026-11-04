# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :openai_access_token,
  :client_id, :application_id, :consumer_key, :snaptrade_user_id, :snaptrade_user_secret,
  :oauth_access_token, :oauth_refresh_token, :code_verifier, :code_challenge,
  /\Apin\z/i,
  # One-time codes that act as credentials: MFA TOTP/backup codes, OAuth and
  # bank authorization codes and the desktop SSO exchange all arrive as
  # "code". Anchored so currency_code, country_code and postal_code stay
  # readable. linking_code binds a mobile SSO login to an account,
  # invite_code opens registration, and access_url is SimpleFIN's credential.
  /\Acode\z/i, :linking_code, :invite_code, :access_url,
  # A device code redeems into tokens on its own, so it is a bearer credential in
  # transit; verification_uri_complete embeds the user code, hence all three.
  :device_code, :user_code, :verification_uri_complete,
  :bank_username, :bank_password, :security_answers, :captcha_input,
  # FinanceKit publisher bodies. Anchored: an unanchored :credential also hides
  # credential_id and has_*_credentials, and :events any key containing "events".
  /\A(publisher_)?credential\z/i, /\Aevents\z/i, /\Aconsent\z/i, /\Abooked_balance\z/i
]

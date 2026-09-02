# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :openai_access_token,
  :client_id, :consumer_key, :snaptrade_user_id, :snaptrade_user_secret,
  :oauth_access_token, :oauth_refresh_token, :code_verifier, :code_challenge,
  # A device code redeems into tokens on its own, so it is a bearer credential in
  # transit; verification_uri_complete embeds the user code, hence all three.
  :device_code, :user_code, :verification_uri_complete,
  :bank_username, :bank_password, :security_answers, :captcha_input,
  :bank_username, :bank_password, :security_answers, :captcha_input,
  # Whole-bundle credential pastes. open-banking.io's `credentials_json` carries an API key
  # AND the PKCS#8 private key that decrypts every zero-knowledge envelope, and it matches
  # none of the substrings above -- unlike `app_token`/`api_key`, which `:token`/`:_key`
  # already cover for the other providers.
  :credentials_json, :private_key
]

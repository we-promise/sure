# Whether an SSO callback's email was verified by the identity provider.
#
# JIT account creation and invitation redemption trust the IdP's email, so they
# require it to be verified (see docs/hosting/oidc.md). Linking an existing
# account is unaffected: it requires that account's password.
module SsoEmailVerification
  module_function

  def verified?(auth)
    return false if auth.nil? || auth.info&.email.blank?

    case strategy_for(auth.provider)
    when "github"
      # The github strategy only returns the primary email when it is verified
      # (user:email scope); its verified flags are in extra.all_emails.
      github_email_verified?(auth)
    when "saml"
      # SAML has no email_verified attribute: the email is asserted by the
      # IdP the administrator configured, as for every other SAML attribute.
      true
    else
      # OpenID Connect and Google report the email_verified claim. Some IdPs
      # send it as the string "true".
      claim = auth.info&.email_verified
      claim = raw_info_value(auth, "email_verified") if claim.nil?
      claim == true || claim.to_s.casecmp?("true")
    end
  end

  def strategy_for(provider)
    config = Rails.configuration.x.auth.sso_providers&.find { |p| p[:name].to_s == provider.to_s }
    (config&.dig(:strategy) || provider).to_s
  end

  def github_email_verified?(auth)
    emails = auth.extra&.all_emails
    return false unless emails.respond_to?(:any?)

    email = auth.info.email.to_s.downcase
    emails.any? { |entry| entry["email"].to_s.downcase == email && entry["verified"] == true }
  end

  def raw_info_value(auth, key)
    raw_info = auth.extra&.raw_info
    return nil unless raw_info.respond_to?(:[])

    raw_info[key] || raw_info[key.to_sym]
  end
end

# Whether an SSO callback's email was verified by the identity provider.
#
# JIT account creation and invitation redemption trust the IdP's email, so they
# require it to be verified (see docs/hosting/oidc.md). Linking an existing
# account is unaffected: it requires that account's password.
#
# A missing claim counts as unverified. Administrators can opt a provider in
# with the treat_email_as_verified setting, which is only safe for IdPs where
# users cannot set or change their own email.
module SsoEmailVerification
  module_function

  def verified?(auth)
    return false if auth.nil? || auth.info&.email.blank?

    config = provider_config_for(auth.provider)
    return true if treat_email_as_verified?(config)

    case (config&.dig(:strategy) || auth.provider).to_s
    when "github"
      # The github strategy only returns the primary email when it is verified
      # (user:email scope); its verified flags are in extra.all_emails.
      github_email_verified?(auth)
    when "saml"
      # SAML has no email_verified attribute: the email is asserted by the
      # IdP the administrator configured, as for every other SAML attribute.
      true
    else
      # OpenID Connect and Google report the email_verified claim. Microsoft
      # Entra ID omits it by default but can send the optional xms_edov claim
      # (email domain owner verified) instead.
      claim = auth.info&.email_verified
      claim = raw_info_value(auth, "email_verified") if claim.nil?
      claim = raw_info_value(auth, "xms_edov") if claim.nil?
      true_claim?(claim)
    end
  end

  def provider_config_for(provider)
    Rails.configuration.x.auth.sso_providers&.find { |p| p[:name].to_s == provider.to_s }
  end

  def treat_email_as_verified?(config)
    settings = (config&.dig(:settings) || {}).to_h.with_indifferent_access
    true_claim?(settings[:treat_email_as_verified])
  end

  # Some IdPs send boolean claims as strings, and form checkboxes submit "1".
  def true_claim?(value)
    value == true || value.to_s.downcase.in?(%w[true 1])
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

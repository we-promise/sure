# frozen_string_literal: true

# An allow-list for a provider's outbound base URL.
#
# Several providers let an operator override where the app sends their API
# requests. Left unchecked that is a server-side request forgery: the value is
# whatever a user typed, and the request carries their credentials, so pointing
# it at 169.254.169.254 or an address inside the network makes the server fetch
# it and hands the token over with it.
#
# Provider::Brex already worked this way; this is that logic, shared.
#
#   class Provider::Foo
#     extend BaseUrlAllowlistable
#
#     DEFAULT_BASE_URL = "https://api.foo.com/v1"
#     ALLOWED_BASE_URLS = [ DEFAULT_BASE_URL, "https://api-sandbox.foo.com/v1" ].freeze
#   end
module BaseUrlAllowlistable
  # Returns the canonical form of an allowed URL, or nil when it is not on the
  # list. A blank value means "unset", which resolves to the default.
  def normalize_base_url(value)
    stripped = value.to_s.strip
    return self::DEFAULT_BASE_URL if stripped.blank?

    canonical = BaseUrlAllowlistable.canonicalize(stripped)
    return nil if canonical.nil?

    allowed = self::ALLOWED_BASE_URLS.filter_map { |url| BaseUrlAllowlistable.canonicalize(url) }
    allowed.include?(canonical) ? canonical : nil
  end

  def allowed_base_url?(value)
    normalize_base_url(value).present?
  end

  # Reduces a URL to the parts the allow-list compares, and refuses anything
  # that cannot be compared safely. HTTPS only, no credentials in the URL, no
  # query or fragment, and no non-default port, so a value cannot smuggle past
  # the comparison by carrying something the allow-list does not mention.
  def self.canonicalize(value)
    uri = URI.parse(value.to_s.strip)
    return nil unless uri.is_a?(URI::HTTPS)
    return nil if uri.host.blank?
    return nil if uri.userinfo.present? || uri.query.present? || uri.fragment.present?
    return nil unless uri.port == uri.default_port

    "#{uri.scheme.downcase}://#{uri.host.downcase}#{uri.path.to_s.chomp('/')}"
  rescue URI::InvalidURIError
    nil
  end
end

# Validates OAuth client metadata (redirect URIs and client names) shared
# across Dynamic Client Registration (RFC 7591) and Client ID Metadata
# Documents (CIMD).
module Oauth::ClientMetadataValidator
  LOOPBACK_HOSTS = [ "localhost", "127.0.0.1", "::1" ].freeze
  # Schemes that can execute script, read local files, invoke device handlers,
  # or are not OAuth redirects.
  FORBIDDEN_SCHEMES = %w[javascript data file about blob ws wss ftp mailto tel sms intent].freeze
  SCHEME_PATTERN = /\A[a-z][a-z0-9+\-.]*\z/.freeze
  # Client names containing the word "Sure" are reserved for first-party apps
  # (e.g. "Sure Mobile"), so a registered client cannot pose as one on the
  # consent screen or share the mobile app's name.
  RESERVED_CLIENT_NAME_WORD = "sure"
  # Lowercase Cyrillic, Greek and Armenian letters that look like the Latin
  # letters of "sure mobile" (NFKC keeps them apart), e.g. "Ѕurе" with a
  # Cyrillic Ѕ and е. Uppercase look-alikes such as М and В arrive here
  # already downcased.
  CONFUSABLE_LETTERS = "ѕսυуеοоіιӏмвг"
  CONFUSABLE_LATIN = "suuueooiilmbr"

  module_function

  def normalize_redirect_uris(raw_uris)
    return [] if raw_uris.blank?

    Array(raw_uris).map { |uri| uri.to_s.strip }.reject(&:blank?)
  end

  # Bidi controls can make the consent screen show a name that differs from
  # the stored text (e.g. U+202E "eruS" renders as "Sure"), so reject them
  # instead of stripping them.
  def bidi_control?(name)
    name.to_s.match?(/\p{Bidi_Control}/)
  end

  # Matches "Sure" as a whole word, ignoring case, punctuation, invisible
  # characters (format characters plus every default-ignorable code point,
  # such as the combining grapheme joiner, variation selectors and Hangul
  # fillers), combining marks NFKC cannot compose (e.g. U+0332 after "S"), full-width
  # letters and common look-alike letters, plus words starting with
  # "SureMobile". Consecutive words are joined too, so separators inside the
  # word ("S u r e", "S.u.r.e", "S-u-r-e") do not get around the check.
  # "Surefire" or "Measure Mobile" stay allowed.
  def reserved_client_name?(name)
    normalized = name.to_s.unicode_normalize(:nfkc).downcase.gsub(/[\p{Cf}\p{Mn}\p{Me}\p{Default_Ignorable_Code_Point}]/, "")
      .tr(CONFUSABLE_LETTERS, CONFUSABLE_LATIN)
    words = normalized.scan(/[[:alnum:]]+/)
    reserved_prefix = "#{RESERVED_CLIENT_NAME_WORD}mobile"

    words.each_index do |start|
      joined = +""
      words.drop(start).each do |word|
        joined << word
        return true if joined == RESERVED_CLIENT_NAME_WORD || joined.start_with?(reserved_prefix)
        break unless reserved_prefix.start_with?(joined)
      end
    end

    false
  end

  # Returns true for https, loopback http, and RFC 8252 private-use schemes
  # (cursor://, vscode://). Rejects fragments, userinfo, handler schemes, and
  # non-loopback http.
  def valid_redirect_uri?(raw_uri)
    uri = URI.parse(raw_uri)
    return false unless uri.fragment.nil?
    return false if uri.userinfo.present?

    scheme = uri.scheme.to_s.downcase
    return false if scheme.blank? || FORBIDDEN_SCHEMES.include?(scheme)
    return false unless scheme.match?(SCHEME_PATTERN)

    case scheme
    when "https"
      uri.host.present?
    when "http"
      loopback_http?(uri)
    else
      native_app_redirect?(uri)
    end
  rescue URI::Error
    false
  end

  # Returns true when +uri+ is http to localhost, 127.0.0.1, or ::1.
  def loopback_http?(uri)
    return false if uri.host.blank?

    host = uri.host.downcase.delete_prefix("[").delete_suffix("]")
    LOOPBACK_HOSTS.include?(host)
  end
  private_class_method :loopback_http?

  # Returns true when a private-use URI has a host or path to redirect to.
  def native_app_redirect?(uri)
    uri.host.present? || uri.path.present?
  end
  private_class_method :native_app_redirect?
end

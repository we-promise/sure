# Masks bank and brokerage identifiers (IBANs, account numbers) down to their
# last 4 characters, e.g. "•••1234".
#
# Meant for identifiers only. A value of 4 characters or fewer is shown in
# full ("123" becomes "•••123"), which is fine for an account number but would
# leak a short secret, so never use this for API keys, tokens or passwords.
# Wallet addresses and money amounts follow their own display rules as well.
#
# Lives outside ApplicationHelper so models that build display names can use
# it too; ApplicationHelper#mask_last4 delegates here.
module IdentifierMask
  PREFIX = "•••"

  module_function

  # Returns the masked value, or nil when there is nothing to show.
  #
  # strip_whitespace: drop spaces first, for identifiers that providers
  #   deliver grouped ("DE89 3704 ...").
  # hide_short: return nil instead of the whole value when it has fewer than
  #   4 characters.
  # prefix: the marker in front of the last 4 characters.
  def last4(value, prefix: PREFIX, strip_whitespace: false, hide_short: false)
    digits = last4_chars(value, strip_whitespace:, hide_short:)
    digits && "#{prefix}#{digits}"
  end

  # The last 4 characters on their own, for callers that render their own
  # marker around them.
  def last4_chars(value, strip_whitespace: false, hide_short: false)
    cleaned = value.to_s
    cleaned = cleaned.gsub(/\s+/, "") if strip_whitespace
    return nil if cleaned.blank?
    return nil if hide_short && cleaned.length < 4

    cleaned.last(4)
  end
end

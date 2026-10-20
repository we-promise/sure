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
  # strip_dashes: drop dashes first, for identifiers formatted with them
  #   (Akahu's "12-3456-7890123-00"), so the suffix does not crowd out digits.
  # hide_short: return nil instead of the whole value when it has fewer than
  #   4 characters.
  # prefix: the marker in front of the last 4 characters.
  def last4(value, prefix: PREFIX, strip_whitespace: false, strip_dashes: false, hide_short: false)
    digits = last4_chars(value, strip_whitespace:, strip_dashes:, hide_short:)
    digits && "#{prefix}#{digits}"
  end

  # The last 4 characters on their own, for callers that render their own
  # marker around them.
  def last4_chars(value, strip_whitespace: false, strip_dashes: false, hide_short: false)
    cleaned = value.to_s
    cleaned = cleaned.gsub(/\s+/, "") if strip_whitespace
    cleaned = cleaned.delete("-") if strip_dashes
    return nil if cleaned.blank?
    return nil if hide_short && cleaned.length < 4

    cleaned.last(4)
  end

  # Keys under which providers store a full account identifier in
  # Transaction#extra: counterparty IBANs and account numbers (Monobank, Fio,
  # Akahu), and whatever an institution puts into SimpleFIN's free-form extra.
  # A key matches when its last words name an identifier, in any casing
  # ("routingNumber", "counter_iban"), so "counter_account_name" or
  # "account_number_last_4" are left alone. Every value under a matching key
  # is cut down to its last 4 characters before anything is displayed.
  IDENTIFIER_KEY = /\A(?:.*_)?(?:ibans?|bban|edrpou|pan|acc(?:oun)?t_(?:number|no|num)|routing_(?:number|no)|sort_code|card_number|counter_account|other_account)\z/

  def identifier_key?(key)
    key.to_s.underscore.match?(IDENTIFIER_KEY)
  end

  # Returns a copy of a provider payload (Transaction#extra) with every value
  # under an identifier key masked.
  def mask_identifiers(value, mask_all: false)
    case value
    when Hash
      value.to_h do |key, child|
        [ key, mask_identifiers(child, mask_all: mask_all || identifier_key?(key)) ]
      end
    when Array
      value.map { |item| mask_identifiers(item, mask_all:) }
    when String, Numeric
      mask_all ? mask_identifier(value) : value
    else
      value
    end
  end

  # Czech-style "<account>/<bank code>" keeps the bank code, which on its own
  # identifies no one, so the masked account part stays recognizable.
  # Grouping spaces and dashes are dropped first, so a grouped IBAN or an Akahu
  # account number masks to the same digits here as in notes and setup views.
  def mask_identifier(value)
    account, bank_code = value.to_s.split("/", 2)
    return last4(value, strip_whitespace: true, strip_dashes: true) unless bank_code.present? && bank_code.match?(/\A\d{4}\z/)

    "#{last4(account, strip_whitespace: true, strip_dashes: true)}/#{bank_code}"
  end
end

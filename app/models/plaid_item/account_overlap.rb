# Compares the accounts Plaid Link reported for a new connection with the accounts of
# the connections a user already holds at that institution, so the duplicate warning
# can say what the new connection would duplicate instead of asking which login the
# user signed in with -- a returning user comes through Plaid's phone-number flow
# with no bank login, and Link may preselect every account or skip account selection
# altogether.
#
# Plaid's duplicate-Items guidance is to compare institution, account name and mask.
# The institution has already matched by the time this runs, so it compares name and
# mask: Plaid issues new account ids for every Item, so ids never match across them.
class PlaidItem::AccountOverlap
  attr_reader :link_accounts

  # `link_accounts` is the `accounts` array from Link's onSuccess metadata, each with
  # a "name" and a "mask". `plaid_items` are the existing connections the duplicate
  # check matched.
  def initialize(link_accounts:, plaid_items:)
    @link_accounts = Array(link_accounts).map { |account| account.to_h.stringify_keys.slice("name", "mask") }
    @plaid_items = plaid_items
  end

  # :all_connected, :some_connected or :none_connected -- or :unknown when the
  # comparison can't be trusted:
  # - Link reported no accounts.
  # - A reported account has no mask. Brokerages and crypto exchanges often report
  #   none, with generic names such as "Brokerage", so a different login's accounts
  #   can match on name alone -- and an :all_connected verdict hides the dialog's
  #   override.
  # - A matching connection has no accounts on record yet because its first sync
  #   never landed, so any account Link reported might be one of its accounts.
  def state
    return :unknown if link_accounts.empty? || link_accounts.any? { |account| account["mask"].blank? }
    return :unknown if plaid_items.any? { |item| item.plaid_accounts.empty? }
    return :all_connected if unconnected_accounts.empty?

    unconnected_accounts.size == link_accounts.size ? :none_connected : :some_connected
  end

  def unconnected_accounts
    @unconnected_accounts ||= link_accounts.reject { |account| connected_keys.include?(key_for(account["name"], account["mask"])) }
  end

  def connected_count
    link_accounts.size - unconnected_accounts.size
  end

  # The connections holding at least one reported account -- the ones this link
  # actually overlaps. A family can hold several connections at one institution, often
  # for different logins, and the others have nothing to do with this one. Empty when
  # nothing matches.
  def matching_items
    @matching_items ||= plaid_items.select do |item|
      item.plaid_accounts.any? { |account| link_keys.include?(key_for(account.name, account.mask)) }
    end
  end

  private
    attr_reader :plaid_items

    def link_keys
      @link_keys ||= link_accounts.to_set { |account| key_for(account["name"], account["mask"]) }
    end

    def connected_keys
      @connected_keys ||= plaid_items.flat_map(&:plaid_accounts).to_set { |account| key_for(account.name, account.mask) }
    end

    def key_for(name, mask)
      [ name.to_s.strip.downcase, mask.to_s.strip ]
    end
end

class BalanceSheet::AccountGroup
  include Monetizable

  monetize :total, as: :total_money

  attr_reader :name, :color, :accountable_type, :accounts

  # Several accounts of the group held at one institution (the currency
  # balances of a Wise account, say: the same institution name and URL),
  # shown in the sidebar as one entry with their combined total: in their own
  # currency when they all share one, else in the family's, unless the
  # institution's group (an InstitutionGroup, `settings`) chooses a currency
  # or a name. The entry shows the group's own icon.
  InstitutionBundle = Data.define(:key, :group_key, :name, :accounts, :total, :currency, :converted_total, :settings) do
    include Monetizable

    monetize :total, as: :total_money

    # Names the bundle in URLs and DOM ids: the key itself can hold any
    # character, and an institution can have a bundle in more than one group.
    def slug
      "#{group_key}-#{Digest::MD5.hexdigest(key)[0, 12]}"
    end

    def to_param
      slug
    end

    # The account the bundle takes its defaults from: its first account in
    # the user's Default Account Order (the balance sheet sorts each group's
    # accounts so, and a bundle keeps that order). Its institution's name
    # (else its domain) and its domain are the bundle's unless the settings
    # name it otherwise; the group took its icon when it formed.
    def lead_account
      accounts.first
    end

    def inherited_name
      lead_account.institution_name.presence || inherited_domain
    end

    def inherited_domain
      lead_account.institution_domain.presence
    end

    # The group's icon, as an account's shows (see InstitutionGroup#logo_preview),
    # else what its first account falls back to (Brandfetch's for the domain,
    # the provider's); its accounts keep their own.
    def logo_url
      return lead_account.logo_url unless settings

      settings.logo_preview(lead_account, name: name).logo_url || lead_account.fallback_logo_url
    end

    def syncing?
      accounts.any?(&:syncing?)
    end

    # The accounts' combined balance history in the bundle's currency, over
    # the accounts its total counts.
    # Changes whenever the bundle's sparkline does: with any of its counted
    # accounts' sparklines (Account#sparkline_version), which accounts it
    # counts (a shared account left out of the viewer's finances drops out),
    # or the currency it is shown in. The sidebar passes the versions it
    # already has.
    def sparkline_version(account_versions = Account.sparkline_versions(accounts.map(&:account)))
      counted = BalanceSheet::ClassificationGroup.counted_accounts(accounts)
      rows = counted.map { |account| "#{account.id}:#{account_versions[account.id]}" }.sort
      Digest::SHA256.hexdigest([ slug, currency, *rows ].join("|")).first(16)
    end

    def sparkline_series
      balance_series(period: Period.last_30_days)
    end

    # Linked investment and crypto accounts are trimmed to the history their
    # providers support together, as the account group's sparkline is
    # (AccountableSparkline), so a portfolio imported later isn't drawn as
    # growth.
    def balance_series(period:)
      options = {
        account_ids: BalanceSheet::ClassificationGroup.counted_accounts(accounts).map(&:id),
        currency: currency,
        period: period,
        favorable_direction: accounts.first.favorable_direction
      }
      if linked_investments?
        Balance::LinkedInvestmentSeriesNormalizer.aggregate_account_ids(**options, interval: nil)
      else
        Balance::ChartSeriesBuilder.new(**options).balance_series
      end
    end

    def linked_investments?
      accounts.any? { |row| row.account.accountable_type.in?(%w[Investment Crypto]) && row.account.linked? }
    end

    # When the earliest of the accounts' histories starts, or nil.
    def history_start_date
      accounts.filter_map(&:history_start_date).min
    end

    def dom_id(prefix)
      "#{prefix}_institution_#{Digest::MD5.hexdigest(key)[0, 12]}"
    end
  end

  def initialize(name:, color:, accountable_type:, accounts:, classification_group:)
    @name = name
    @color = color
    @accountable_type = accountable_type
    @accounts = accounts
    @classification_group = classification_group
  end

  # A stable DOM id for this group.
  # Example outputs:
  #   dom_id(tab: :asset)               # => "asset_depository"
  #   dom_id(tab: :all, mobile: true)   # => "mobile_all_depository"
  #
  # Keeping all of the logic here means the view layer and broadcaster only
  # need to ask the object for its DOM id instead of rebuilding string
  # fragments in multiple places.
  def dom_id(tab: nil, mobile: false)
    parts = []
    parts << "mobile" if mobile
    parts << (tab ? tab.to_s : classification.to_s)
    parts << key
    parts.compact.join("_")
  end

  def key
    accountable_type.to_s.underscore
  end

  # Counts the same accounts as the classification total and net worth, so the
  # group weights add up and the sidebar sparkline matches this figure.
  def total
    BalanceSheet::ClassificationGroup.counted_accounts(accounts).sum(&:converted_balance)
  end

  def weight
    return 0 if classification_group.total.zero?

    total / classification_group.total.to_d * 100
  end

  def syncing?
    accounts.any?(&:syncing?)
  end

  # The group's sidebar rows: an account, or a bundle where two or more
  # accounts share an institution (its name and domain, ignoring case and
  # spacing; see InstitutionGroup.key_for). With a name or balance order the rows sort by what each shows,
  # a bundle by its institution's name or its total (balances compared in the
  # family's currency); otherwise a bundle takes its first account's place.
  # A bundle's accounts keep the group's order.
  # `institution_groups` holds the family's institution groups by key; a
  # bundle without one forms it (InstitutionGroup.form), and it is added.
  def sidebar_entries(order: nil, institution_groups: {})
    entries = sidebar_rows(institution_groups)
    case order&.key
    when "name_asc", "name_desc"
      sorted = entries.each_with_index.sort_by { |entry, index| [ entry_name(entry).downcase, index ] }.map(&:first)
      order.key == "name_desc" ? sorted.reverse : sorted
    when "balance_asc", "balance_desc"
      sorted = entries.each_with_index.sort_by { |entry, index| [ entry_balance(entry), index ] }.map(&:first)
      order.key == "balance_desc" ? sorted.reverse : sorted
    else
      entries
    end
  end

  def institution_bundles(institution_groups: {})
    sidebar_rows(institution_groups).grep(InstitutionBundle)
  end

  # The bundle whose slug ends in `digest` (InstitutionBundle#slug), built
  # alone, or nil.
  def institution_bundle_by_digest(digest, institution_groups: {})
    key, members = accounts.group_by { |account| institution_key(account) }
      .find { |candidate, sharing| candidate && sharing.size >= 2 && Digest::MD5.hexdigest(candidate)[0, 12] == digest }
    institution_bundle(key, members.first, members, institution_groups) if key
  end

  private def sidebar_rows(institution_groups)
    by_institution = accounts.group_by { |account| institution_key(account) }
    bundled = Set.new

    accounts.filter_map do |account|
      key = institution_key(account)
      members = key ? by_institution[key] : []
      next account if members.size < 2
      next if bundled.include?(key)

      bundled << key
      institution_bundle(key, account, members, institution_groups)
    end
  end

  private def institution_bundle(key, first_account, members, institution_groups)
    settings = institution_groups[key] ||= InstitutionGroup.form(key, members)
    counted = BalanceSheet::ClassificationGroup.counted_accounts(members)
    shared_currency = members.map(&:currency).uniq.one? ? members.first.currency : nil
    display_currency = settings&.currency || shared_currency || currency

    InstitutionBundle.new(
      key: key,
      group_key: self.key,
      name: settings&.name || first_account.institution_name.presence || first_account.institution_domain,
      accounts: members,
      total: total_in(counted, display_currency),
      currency: display_currency,
      converted_total: counted.sum(&:converted_balance),
      settings: settings
    )
  end

  # The accounts' balances summed in `target`: each account's own balance in
  # that currency, the balance sheet's conversion in the family's, and today's
  # rates (fetched together) in any other.
  private def total_in(counted, target)
    return counted.sum(&:converted_balance) if target == currency

    rates = ExchangeRate.rates_for(counted.map(&:currency) - [ target ], to: target)
    counted.sum { |account| account.currency == target ? account.balance : account.balance * rates.fetch(account.currency) }
  end

  # "asset" or "liability"
  def classification
    classification_group.classification
  end

  def currency
    classification_group.currency
  end

  private
    attr_reader :classification_group

    def entry_name(entry)
      entry.name.to_s
    end

    def entry_balance(entry)
      entry.is_a?(InstitutionBundle) ? entry.converted_total : entry.converted_balance
    end

    def institution_key(account)
      InstitutionGroup.key_for(account)
    end
end

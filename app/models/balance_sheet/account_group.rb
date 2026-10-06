class BalanceSheet::AccountGroup
  include Monetizable

  monetize :total, as: :total_money

  attr_reader :name, :color, :accountable_type, :accounts

  # accountable_type is nil for a group formed by another dimension than the
  # account type (see AccountGrouping); such groups pass their own key.
  def initialize(name:, color:, accountable_type:, accounts:, classification_group:, key: nil)
    @key = key
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
    @key || accountable_type.to_s.underscore
  end

  # Whether this group holds exactly one account type, so type-specific
  # extras (sparkline, "new account" link) apply.
  def type_group?
    accountable_type.present?
  end

  def total
    accounts.reject { |a| a.respond_to?(:exclude_from_reports?) && a.exclude_from_reports? }.sum(&:converted_balance)
  end

  # Total of all assets or all debts this group belongs to.
  def classification_total
    classification_group.total
  end

  def weight
    return 0 if classification_group.total.zero?

    total / classification_group.total.to_d * 100
  end

  def syncing?
    accounts.any?(&:syncing?)
  end

  # Color for an account row: the group color in a type group, otherwise the
  # account's own type color, so an account looks the same in every grouping.
  def color_for(account)
    type_group? ? color : account.accountable.color
  end

  # Splits the group's accounts by a second dimension (see AccountGrouping).
  # Every group shows the level, even when all its accounts share one value,
  # so the list reads the same in every group. Unknown dimensions return an
  # empty array.
  def subgroups(dimension, user:)
    return [] unless AccountGrouping.valid_dimension?(dimension)

    AccountGrouping.new(dimension, user: user).group(accounts).map do |group|
      BalanceSheet::AccountSubgroup.new(key: group.key, name: group.name, accounts: group.accounts, account_group: self)
    end
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
end

class BalanceSheet::AccountGroup
  include Monetizable

  monetize :total, as: :total_money

  attr_reader :name, :color, :accountable_type, :accounts

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

  def total
    accounts.sum(&:converted_balance)
  end

  def subgroups
    return [] unless cash_subgroup_enabled? && accountable_type == Depository

    grouped_accounts = accounts.group_by { |account| normalized_subtype(account.subtype) }

    order = Depository::SUBTYPES.keys

    grouped_accounts
      .reject { |subtype, _| subtype.nil? }
      .map do |subtype, rows|
        BalanceSheet::SubtypeGroup.new(subtype: subtype, accounts: rows, account_group: self)
      end
      .sort_by do |subgroup|
        idx = order.index(subgroup.subtype)
        [ idx || order.length, subgroup.name ]
      end
  end

  def uncategorized_accounts
    return [] unless cash_subgroup_enabled? && accountable_type == Depository

    accounts.select { |account| normalized_subtype(account.subtype).nil? }
  end

  def uncategorized_total
    uncategorized_accounts.sum(&:converted_balance)
  end

  def uncategorized_total_money
    Money.new((uncategorized_total * 100).to_i, currency)
  end

  def weight
    return 0 if classification_group.total.zero?

    total / classification_group.total.to_d * 100
  end

  def syncing?
    accounts.any?(&:syncing?)
  end

  # "asset" or "liability"
  def classification
    classification_group.classification
  end

  def currency
    classification_group.currency
  end

  def cash_subgroup_enabled?
    classification_group.family.cash_subgroup_enabled != false
  end

  private
    def normalized_subtype(subtype)
      value = subtype&.to_s&.strip&.downcase
      return nil if value.blank?

      Depository::SUBTYPES.key?(value) ? value : nil
    end

    attr_reader :classification_group
end

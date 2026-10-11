class BalanceSheet::ClassificationGroup
  include Monetizable

  monetize :total, as: :total_money

  attr_reader :classification, :currency

  def initialize(classification:, currency:, accounts:)
    @classification = normalize_classification!(classification)
    @name = name
    @currency = currency
    @accounts = accounts
  end

  def name
    I18n.t("pages.dashboard.balance_sheet.classifications.#{classification}", default: classification.titleize.pluralize)
  end

  def icon
    classification == "asset" ? "plus" : "minus"
  end

  def total
    accounts.select { |a| a.respond_to?(:included_in_finances?) ? a.included_in_finances? : true }
            .reject { |a| a.respond_to?(:exclude_from_reports?) && a.exclude_from_reports? }
            .sum(&:converted_balance)
  end

  def syncing?
    accounts.any?(&:syncing?)
  end

  # Groups by account type unless another dimension is given (see
  # AccountGrouping). The split into assets and debts always stays above.
  def account_groups(by: nil, user: nil)
    return dimension_groups(by, user: user) if by.present? && by.to_s != AccountGrouping::DEFAULT_PRIMARY

    groups = accounts.group_by(&:accountable_type)
                     .transform_keys { |at| Accountable.from_type(at) }
                     .map do |accountable, account_rows|
                       BalanceSheet::AccountGroup.new(
                         name: accountable.display_name,
                         color: accountable.color,
                         accountable_type: accountable,
                         accounts: account_rows,
                         classification_group: self
                       )
                     end

    # Sort the groups using the manual order defined by Accountable::TYPES so that
    # the UI displays account groups in a predictable, domain-specific sequence.
    groups.sort_by do |group|
      manual_order = Accountable::TYPES
      type_name    = group.key.camelize
      manual_order.index(type_name) || Float::INFINITY
    end
  end

  private
    attr_reader :accounts

    def dimension_groups(dimension, user:)
      AccountGrouping.new(dimension, user: user).group(accounts).map do |group|
        # Prefixed so an asset and a debt group with the same value stay apart.
        key = "#{classification}_#{AccountGrouping.group_key(dimension, group.key)}"

        BalanceSheet::AccountGroup.new(
          key: key,
          name: group.name,
          color: AccountGrouping.color_for(key),
          accountable_type: nil,
          accounts: group.accounts,
          classification_group: self
        )
      end
    end

    def normalize_classification!(classification)
      raise ArgumentError, "Invalid classification: #{classification}" unless %w[asset liability].include?(classification)
      classification
    end
end

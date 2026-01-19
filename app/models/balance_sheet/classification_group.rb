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
    classification.titleize.pluralize
  end

  def icon
    classification == "asset" ? "plus" : "minus"
  end

  def total
    accounts.sum(&:converted_balance)
  end

  def syncing?
    accounts.any?(&:syncing?)
  end

  # For now, we group by accountable type. This can be extended in the future to support arbitrary user groupings.
  def account_groups
    grouped_accounts = accounts.group_by(&:accountable_type)
    loan_accounts = grouped_accounts.delete("Loan")

    groups = grouped_accounts
                   .transform_keys { |at| Accountable.from_type(at) }
                   .map { |accountable, account_rows| build_account_group(accountable, account_rows) }

    if loan_accounts
      installment_accounts, standard_loans = loan_accounts.partition(&:installment)
      groups << build_account_group(Loan, standard_loans) if standard_loans.any?
      groups << build_account_group(Loan, installment_accounts, name_key: "installment") if installment_accounts.any?
    end

    # Sort the groups using the manual order defined by Accountable::TYPES so that
    # the UI displays account groups in a predictable, domain-specific sequence.
    groups.sort_by do |group|
      manual_order = Accountable::TYPES
      index = manual_order.index(group.accountable_type.name) || Float::INFINITY
      group.key == "installment" ? index + 0.1 : index
    end
  end


  private
    attr_reader :accounts

    def build_account_group(accountable, account_rows, name_key: nil)
      group_key = name_key || accountable.name.underscore
      display_name = group_key == "installment" ? I18n.t("accounts.types.installment", default: "Installment") : accountable.display_name

      BalanceSheet::AccountGroup.new(
        name: I18n.t("accounts.types.#{group_key}", default: display_name),
        color: accountable.color,
        accountable_type: accountable,
        accounts: account_rows,
        classification_group: self,
        group_key: group_key
      )
    end

    def normalize_classification!(classification)
      raise ArgumentError, "Invalid classification: #{classification}" unless %w[asset liability].include?(classification)
      classification
    end
end

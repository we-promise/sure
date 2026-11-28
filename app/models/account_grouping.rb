# Grouping levels for account lists (sidebar, dashboard balance sheet).
#
# Below the fixed split into assets and debts, the user picks per view which
# dimension forms the first level (default: account type) and, optionally,
# which one splits each first-level group again. Every dimension maps an
# account to exactly one value, so group totals always add up to the total one
# level above. Accounts without a value land in a trailing "Not set" group,
# whose key is nil so it can never collide with a real value. A dimension that
# an account type's form does not offer (a vehicle has no subtype) groups those
# accounts by their account type instead, whatever value a provider or a
# derived default holds, as "Not set" would ask for a value that cannot be
# entered.
class AccountGrouping
  VIEWS = %w[sidebar dashboard].freeze
  DEFAULT_PRIMARY = "account_type".freeze
  DIMENSIONS = %w[account_type subtype institution connection owner ownership currency tax_treatment custom_group].freeze
  CUSTOM_GROUP_MAX_LENGTH = 50
  # Account types whose form offers the field; dimensions not listed apply to
  # every type.
  APPLICABLE_TYPES = {
    "subtype" => %w[Depository Investment Crypto Property Loan],
    "tax_treatment" => %w[Investment Crypto]
  }.freeze
  # Colors for first-level groups that are not account types.
  COLORS = Category::COLORS

  Group = Data.define(:key, :name, :accounts)

  # Key of a group formed by the account type because the dimension does not
  # apply. Its own class, so no free-text value can ever match it.
  TypeFallback = Data.define(:accountable_type) do
    def to_s
      "accountable_type_#{accountable_type.underscore}"
    end
  end

  attr_reader :dimension, :user

  class << self
    def valid_dimension?(key)
      DIMENSIONS.include?(key.to_s)
    end

    def applies_to?(dimension, accountable_type)
      types = APPLICABLE_TYPES[dimension.to_s]
      types.nil? || types.include?(accountable_type.to_s)
    end

    def dimension_label(key, user: nil)
      return user.custom_account_group_label if key.to_s == "custom_group" && user

      I18n.t("account_grouping.dimensions.#{key}")
    end

    # A stable, DOM-safe key for a first-level group. Values can be free text
    # in any script, so they are hashed.
    def group_key(dimension, value)
      "#{dimension}_#{Digest::SHA256.hexdigest(value.to_s).first(12)}"
    end

    # A color derived from the group key, so a group keeps its color when
    # other groups are added or removed.
    def color_for(group_key)
      COLORS[Digest::SHA256.hexdigest(group_key.to_s).to_i(16) % COLORS.size]
    end

    # Collapses case and whitespace so "ING", " ing " and "Ing" share a group.
    def normalize(value)
      value.to_s.squish.downcase.presence
    end
  end

  def initialize(dimension, user:)
    raise ArgumentError, "Invalid grouping dimension: #{dimension}" unless self.class.valid_dimension?(dimension)

    @dimension = dimension.to_s
    @user = user
  end

  # Splits the given (already sorted) accounts into groups. Account order
  # inside each group is preserved; groups are sorted by name (account types in
  # their usual order) with the "Not set" group last.
  def group(accounts)
    accounts.group_by { |account| value_key_for(account) }
            .map { |key, rows| Group.new(key: key, name: display_name_for(key, rows), accounts: rows) }
            .sort_by { |group| [ group.key.nil? ? 1 : 0, sort_value_for(group) ] }
  end

  private
    def value_key_for(account)
      unless self.class.applies_to?(dimension, account.accountable_type)
        return TypeFallback.new(accountable_type: account.accountable_type)
      end

      value = case dimension
      when "account_type" then account.accountable_type.presence
      when "subtype" then account.subtype.presence
      when "institution" then self.class.normalize(account.institution_name)
      when "connection" then account.provider_name.presence || "manual"
      when "owner" then account.owner_id
      when "ownership" then ownership_for(account)
      when "currency" then account.currency.presence
      when "tax_treatment" then account.tax_treatment&.to_s
      when "custom_group" then self.class.normalize(account.custom_group)
      end

      value.presence
    end

    # Values that only differ in case or spacing share a group; its label is
    # the most common spelling (ties: alphabetically first), independent of
    # account order.
    def display_name_for(key, rows)
      rows.map { |account| name_for(key, account) }
          .tally
          .min_by { |name, count| [ -count, name ] }
          .first
    end

    def name_for(key, account)
      return I18n.t("account_grouping.none") if key.nil?
      return account.accountable_class.display_name if key.is_a?(TypeFallback)

      case dimension
      when "account_type" then Accountable.from_type(key).display_name
      when "subtype" then account.long_subtype_label
      when "institution" then account.institution_name.to_s.squish
      when "connection" then I18n.t("account_grouping.connections.#{key}", default: key.to_s.titleize)
      when "owner" then account.owner&.display_name || I18n.t("account_grouping.none")
      when "ownership" then I18n.t("account_grouping.ownership.#{key}")
      when "currency" then key
      when "tax_treatment" then account.tax_treatment_label
      when "custom_group" then account.custom_group.to_s.squish
      end
    end

    def sort_value_for(group)
      return [ Accountable::TYPES.index(group.key) || Accountable::TYPES.size, "" ] if dimension == "account_type"

      [ 0, group.name.downcase ]
    end

    def ownership_for(account)
      return nil if account.owner_id.nil? || user.nil?

      account.owner_id == user.id ? "mine" : "shared_with_me"
    end
end

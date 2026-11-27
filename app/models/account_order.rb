class AccountOrder
  include ActiveModel::Model
  include ActiveModel::Attributes

  ORDERS = {
    "name_asc" => {
      label: "Name (A-Z)",
      label_short: "Name ↑",
      sql_order: "name ASC"
    },
    "name_desc" => {
      label: "Name (Z-A)",
      label_short: "Name ↓",
      sql_order: "name DESC"
    },
    "balance_asc" => {
      label: "Balance (Low to High)",
      label_short: "Balance ↑",
      sql_order: "balance ASC"
    },
    "balance_desc" => {
      label: "Balance (High to Low)",
      label_short: "Balance ↓",
      sql_order: "balance DESC"
    },
    # Per-user drag-and-drop order, stored in users.preferences. SQL callers
    # fall back to alphabetical; #sort applies the stored order for the
    # sidebar and the portfolio's account cards.
    "manual" => {
      label: "Manual (drag to reorder)",
      label_short: "Manual",
      sql_order: "name ASC"
    }
  }.freeze

  attr_accessor :key

  def initialize(key)
    @key = key.to_s
    raise ArgumentError, "Invalid order key: #{@key}" unless ORDERS.key?(@key)
  end

  def label
    I18n.t("account_order.#{key}.label", default: ORDERS.dig(key, :label))
  end

  def label_short
    I18n.t("account_order.#{key}.label_short", default: ORDERS.dig(key, :label_short))
  end

  def sql_order
    ORDERS.dig(key, :sql_order)
  end

  def manual?
    key == "manual"
  end

  # Puts accounts in this order, as the sidebar lists them. Each account
  # answers name and id; the balance orders read `balance` (the balance in the
  # family's currency; a NULL balance counts as 0) and the manual order reads
  # `manual_order`, the user's saved ids by account group. Array#sort_by isn't stable, so the id settles
  # ties and the order stays fixed between renders.
  def sort(accounts, manual_order: {}, balance: :converted_balance.to_proc)
    case key
    when "name_asc" then sort_by_name(accounts)
    when "name_desc" then sort_by_name(accounts).reverse
    when "balance_asc" then sort_by_balance(accounts, balance)
    when "balance_desc" then sort_by_balance(accounts, balance).reverse
    when "manual" then sort_manually(accounts, manual_order)
    else accounts
    end
  end

  class << self
    def all
      ORDERS.keys.map { |key| new(key) }
    end

    def find(key)
      new(key) if ORDERS.key?(key.to_s)
    end

    def default
      new("name_asc")
    end
  end

  private
    def sort_by_name(accounts)
      accounts.sort_by { |account| [ NameSortKey.for(account.name), account.id ] }
    end

    def sort_by_balance(accounts, balance)
      accounts.sort_by { |account| [ balance.call(account) || 0, account.id ] }
    end

    # Groups run in the sidebar's order (Accountable::TYPES), since saved
    # positions count within a group. In each, accounts the user has dragged
    # into place come first, in their saved position; accounts added since
    # then follow alphabetically.
    def sort_manually(accounts, manual_order)
      positions = manual_order.values.flat_map { |ids| ids.each_with_index.to_a }.to_h

      accounts.sort_by do |account|
        position = positions[account.id]
        group = Accountable::TYPES.index(account.accountable_type) || Accountable::TYPES.size
        [ group, position ? 0 : 1, position || 0, NameSortKey.for(account.name), account.id.to_s ]
      end
    end
end

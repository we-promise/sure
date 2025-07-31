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
    }
  }.freeze

  attr_accessor :key

  def initialize(key)
    @key = key.to_s
    raise ArgumentError, "Invalid order key: #{@key}" unless ORDERS.key?(@key)
  end

  def label
    ORDERS.dig(key, :label)
  end

  def label_short
    ORDERS.dig(key, :label_short)
  end

  def sql_order
    ORDERS.dig(key, :sql_order)
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
end

class Category < ApplicationRecord
  has_many :transactions, dependent: :nullify, class_name: "Transaction"
  has_many :import_mappings, as: :mappable, dependent: :destroy, class_name: "Import::Mapping"

  belongs_to :family

  has_many :budget_categories, dependent: :destroy
  has_many :subcategories, class_name: "Category", foreign_key: :parent_id, dependent: :nullify
  belongs_to :parent, class_name: "Category", optional: true

  validates :name, :color, :lucide_icon, :family, presence: true
  validates :name, uniqueness: { scope: :family_id }

  validate :category_level_limit
  validate :nested_category_matches_parent_classification

  before_save :inherit_color_from_parent

  scope :alphabetically, -> { order(:name) }
  scope :roots, -> { where(parent_id: nil) }
  scope :incomes, -> { where(classification: "income") }
  scope :expenses, -> { where(classification: "expense") }

  COLORS = %w[#e99537 #4da568 #6471eb #db5a54 #df4e92 #c44fe9 #eb5429 #61c9ea #805dee #6ad28a]

  UNCATEGORIZED_COLOR = "#737373"
  TRANSFER_COLOR = "#444CE7"
  PAYMENT_COLOR = "#db5a54"
  TRADE_COLOR = "#e99537"

  class Group
    attr_reader :category, :subcategories

    delegate :name, :color, to: :category

    def self.for(categories)
      categories.select { |category| category.parent_id.nil? }.map do |category|
        new(category, category.subcategories)
      end
    end

    def initialize(category, subcategories = nil)
      @category = category
      @subcategories = subcategories || []
    end
  end

  class << self
    def icon_codes
      %w[
        ambulance apple award baby banknote barcode bath battery bed-single beer bike
        bluetooth bone book book-open briefcase building bus cake calculator camera
        car cat circle-dollar-sign coffee coins compass cookie cooking-pot credit-card
        dices dog drama drill droplet drum dumbbell film flame flower fuel gamepad-2
        gift glasses globe graduation-cap hammer hand-helping headphones heart
        heart-pulse home house ice-cream-cone key landmark laptop leaf lightbulb
        luggage mail map-pin mic monitor moon music package palette paw-print pen
        pencil phone piggy-bank pill pizza plane plug power printer puzzle receipt
        ribbon scale scissors settings shield shield-plus shirt shopping-bag
        shopping-cart smartphone sparkles sprout stethoscope store sun tag target
        tent thermometer ticket train trees trophy truck tv umbrella users utensils
        video wallet waves wifi wine wrench zap
      ]
    end

    def bootstrap!
      default_categories.each do |name, color, icon, classification|
        find_or_create_by!(name: name) do |category|
          category.color = color
          category.classification = classification
          category.lucide_icon = icon
        end
      end
    end

    def uncategorized
      new(
        name: "Uncategorized",
        color: UNCATEGORIZED_COLOR,
        lucide_icon: "circle-dashed"
      )
    end

    private
      def default_categories
        [
          [ "Income", "#22c55e", "circle-dollar-sign", "income" ],
          [ "Food & Drink", "#f97316", "utensils", "expense" ],
          [ "Groceries", "#407706", "shopping-bag", "expense" ],
          [ "Shopping", "#3b82f6", "shopping-cart", "expense" ],
          [ "Transportation", "#0ea5e9", "bus", "expense" ],
          [ "Travel", "#2563eb", "plane", "expense" ],
          [ "Entertainment", "#a855f7", "drama", "expense" ],
          [ "Healthcare", "#4da568", "pill", "expense" ],
          [ "Personal Care", "#14b8a6", "scissors", "expense" ],
          [ "Home Improvement", "#d97706", "house", "expense" ],
          [ "Mortgage / Rent", "#b45309", "home", "expense" ],
          [ "Utilities", "#eab308", "lightbulb", "expense" ],
          [ "Subscriptions", "#6366f1", "wifi", "expense" ],
          [ "Insurance", "#0284c7", "shield", "expense" ],
          [ "Sports & Fitness", "#10b981", "dumbbell", "expense" ],
          [ "Gifts & Donations", "#61c9ea", "hand-helping", "expense" ],
          [ "Taxes", "#dc2626", "landmark", "expense" ],
          [ "Loan Payments", "#e11d48", "credit-card", "expense" ],
          [ "Services", "#7c3aed", "briefcase", "expense" ],
          [ "Fees", "#6b7280", "receipt", "expense" ],
          [ "Savings & Investments", "#059669", "piggy-bank", "expense" ]
        ]
      end
  end

  def inherit_color_from_parent
    if subcategory?
      self.color = parent.color
    end
  end

  def replace_and_destroy!(replacement)
    transaction do
      transactions.update_all category_id: replacement&.id
      destroy!
    end
  end

  def parent?
    subcategories.any?
  end

  def subcategory?
    parent.present?
  end

  private
    def category_level_limit
      if (subcategory? && parent.subcategory?) || (parent? && subcategory?)
        errors.add(:parent, "can't have more than 2 levels of subcategories")
      end
    end

    def nested_category_matches_parent_classification
      if subcategory? && parent.classification != classification
        errors.add(:parent, "must have the same classification as its parent")
      end
    end

    def monetizable_currency
      family.currency
    end
end

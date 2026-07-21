class Category < ApplicationRecord
  has_many :transactions, dependent: :nullify, class_name: "Transaction"
  has_many :import_mappings, as: :mappable, dependent: :destroy, class_name: "Import::Mapping"

  belongs_to :family

  has_many :budget_categories, dependent: :destroy
  has_many :subcategories,
         -> { order(:name) },
         class_name: "Category",
         foreign_key: :parent_id,
         dependent: :nullify
  belongs_to :parent, class_name: "Category", optional: true

  validates :name, :color, :lucide_icon, :family, presence: true
  validates :color, format: { with: /\A#[0-9A-Fa-f]{6}\z/ }
  validates :name, uniqueness: { scope: :family_id }

  validate :category_level_limit

  before_save :inherit_color_from_parent

  scope :alphabetically, -> { order(:name) }
  scope :alphabetically_by_hierarchy, -> {
    left_joins(:parent)
      .order(Arel.sql("COALESCE(parents_categories.name, categories.name)"))
      .order(Arel.sql("parents_categories.name IS NOT NULL"))
      .order(:name, :id)
  }
  scope :roots, -> { where(parent_id: nil) }
  # Legacy scopes - classification removed; these now return all categories
  scope :incomes, -> { all }
  scope :expenses, -> { all }

  COLORS = %w[#e99537 #4da568 #6471eb #db5a54 #df4e92 #c44fe9 #eb5429 #61c9ea #805dee #6ad28a]

  UNCATEGORIZED_COLOR = "#737373"
  OTHER_INVESTMENTS_COLOR = "#e99537"
  TRANSFER_COLOR = "#444CE7"
  PAYMENT_COLOR = "#db5a54"
  TRADE_COLOR = "#e99537"

  ICON_KEYWORDS = {
    /income|salary|paycheck|wage|earning/                          => "circle-dollar-sign",
    /groceries|grocery|supermarket/                                => "shopping-bag",
    /food|dining|restaurant|meal|lunch|dinner|breakfast/           => "utensils",
    /coffee|cafe|café/                                             => "coffee",
    /shopping|retail/                                              => "shopping-cart",
    /transport|transit|commute|subway|metro/                       => "bus",
    /parking/                                                      => "circle-parking",
    /car|auto|vehicle/                                             => "car",
    /gas|fuel|petrol/                                              => "fuel",
    /flight|airline/                                               => "plane",
    /travel|trip|vacation|holiday/                                 => "plane",
    /hotel|lodging|accommodation/                                  => "hotel",
    /movie|cinema|film|theater|theatre/                            => "film",
    /music|concert/                                                => "music",
    /game|gaming/                                                  => "gamepad-2",
    /entertainment|leisure/                                        => "drama",
    /sport|fitness|gym|workout|exercise/                           => "dumbbell",
    /pharmacy|drug|medicine|pill|medication|dental|dentist/        => "pill",
    /health|medical|clinic|doctor|physician/                       => "stethoscope",
    /personal care|beauty|salon|spa|hair/                          => "scissors",
    /mortgage|rent/                                                => "home",
    /home|house|apartment|housing/                                 => "home",
    /improvement|renovation|remodel/                               => "hammer",
    /repair|maintenance/                                           => "wrench",
    /electric|power|energy/                                        => "zap",
    /water|sewage/                                                 => "waves",
    /internet|cable|broadband|subscription|streaming/              => "wifi",
    /utilities|utility/                                            => "lightbulb",
    /phone|telephone/                                              => "phone",
    /mobile|cell/                                                  => "smartphone",
    /insurance/                                                    => "shield",
    /gift|present/                                                 => "gift",
    /donat|charity|nonprofit/                                      => "hand-helping",
    /tax|irs|revenue/                                              => "landmark",
    /loan|debt|credit card/                                        => "credit-card",
    /service|professional/                                         => "briefcase",
    /fee|charge/                                                   => "receipt",
    /bank|banking/                                                 => "landmark",
    /saving/                                                       => "piggy-bank",
    /invest|stock|fund|portfolio/                                  => "trending-up",
    /pet|dog|cat|animal|vet/                                       => "paw-print",
    /education|school|university|college|tuition/                  => "graduation-cap",
    /book|reading|library/                                         => "book",
    /child|kid|baby|infant|daycare/                                => "baby",
    /cloth|apparel|fashion|wear/                                   => "shirt",
    /ticket/                                                       => "ticket"
  }.freeze

  # Category name keys for i18n
  UNCATEGORIZED_NAME_KEY = "models.category.uncategorized"
  OTHER_INVESTMENTS_NAME_KEY = "models.category.other_investments"
  INVESTMENT_CONTRIBUTIONS_NAME_KEY = "models.category.investment_contributions"
  DEFAULT_CATEGORY_TRANSLATION_KEYS = %w[
    income
    food_and_drink
    groceries
    shopping
    transportation
    travel
    entertainment
    healthcare
    personal_care
    home_improvement
    mortgage_rent
    utilities
    subscriptions
    insurance
    sports_and_fitness
    gifts_and_donations
    taxes
    loan_payments
    services
    fees
    savings_and_investments
  ].freeze

  class Group
    attr_reader :category, :subcategories

    delegate :name, :color, to: :category

    def self.for(categories)
      categories_by_parent_id = categories.to_a.group_by(&:parent_id)

      categories_by_parent_id[nil].to_a.map do |category|
        new(category, categories_by_parent_id[category.id].to_a)
      end
    end

    def initialize(category, subcategories = nil)
      @category = category
      @subcategories = subcategories || []
    end
  end

  class << self
    def ids_with_transactions(family:, category_ids:)
      category_ids = Array(category_ids).compact
      return {} if category_ids.empty?

      family.transactions
            .where(category_id: category_ids)
            .distinct
            .pluck(:category_id)
            .index_with(true)
    end

    def suggested_icon(name)
      name_down = name.to_s.downcase

      ICON_KEYWORDS.each do |pattern, icon|
        return icon if name_down.match?(pattern)
      end

      "shapes"
    end

    def icon_codes
      %w[
        ambulance apple award baby badge-dollar-sign banknote barcode bar-chart-3 bath
        battery bed-single beer bike bluetooth bone book book-open briefcase building bus
        cake calculator calendar-heart calendar-range camera car cat chart-line
        circle-dollar-sign circle-parking coffee coins compass cookie cooking-pot
        credit-card dices dog drama drill droplet drum dumbbell film flame flower flower-2
        fuel gamepad-2 gem gift glasses globe graduation-cap hammer hand-heart
        hand-helping heart-handshake handshake headphones heart heart-pulse home hotel
        house ice-cream-cone key landmark laptop leaf lightbulb luggage mail map-pin
        martini mic monitor moon music package palette party-popper paw-print pen pencil
        percent phone pie-chart piggy-bank pill pizza plane plug popcorn power printer
        puzzle receipt receipt-text ribbon scale scissors settings shield shield-plus
        shirt shopping-bag shopping-basket shopping-cart smartphone sparkles sprout
        stethoscope store sun tablet-smartphone tag target tent thermometer ticket train
        trees tree-palm trending-up trophy truck tv umbrella undo-2 unplug users utensils
        video wallet wallet-cards waves wifi wine wrench zap
      ]
    end

    def bootstrap!
      default_categories.each do |name, color, icon|
        find_or_create_by!(name: name) do |category|
          category.color = color
          category.lucide_icon = icon
        end
      end
    end

    def uncategorized
      new(
        name: I18n.t(UNCATEGORIZED_NAME_KEY),
        color: UNCATEGORIZED_COLOR,
        lucide_icon: "circle-dashed"
      )
    end

    def other_investments
      new(
        name: I18n.t(OTHER_INVESTMENTS_NAME_KEY),
        color: OTHER_INVESTMENTS_COLOR,
        lucide_icon: "trending-up"
      )
    end

    # Helper to get the localized name for uncategorized
    def uncategorized_name
      I18n.t(UNCATEGORIZED_NAME_KEY)
    end

    # Returns all possible uncategorized names across all supported locales
    # Used to detect uncategorized filter regardless of URL parameter language
    def all_uncategorized_names
      LanguagesHelper::SUPPORTED_LOCALES.map do |locale|
        I18n.t(UNCATEGORIZED_NAME_KEY, locale: locale)
      end.uniq
    end

    # Helper to get the localized name for other investments
    def other_investments_name
      I18n.t(OTHER_INVESTMENTS_NAME_KEY)
    end

    # Helper to get the localized name for investment contributions
    def investment_contributions_name
      I18n.t(INVESTMENT_CONTRIBUTIONS_NAME_KEY)
    end

    # Returns all possible investment contributions names across all supported locales
    # Used to detect investment contributions category regardless of locale
    def all_investment_contributions_names
      LanguagesHelper::SUPPORTED_LOCALES.map do |locale|
        I18n.t(INVESTMENT_CONTRIBUTIONS_NAME_KEY, locale: locale)
      end.uniq
    end

    def localized_default_name_for(name)
      i18n_key = default_category_translation_key_for(name)

      i18n_key ? I18n.t(i18n_key, default: name) : name
    end

    private
      def default_category_translation_key_for(name)
        default_category_translation_keys_by_name[name.to_s]
      end

      def default_category_translation_keys_by_name
        @default_category_translation_keys_by_name ||= begin
          # Default categories store the translated name in the `name` column, so
          # older families may have default names from any supported locale. This
          # display-layer bridge maps those known labels back to their i18n key
          # before rendering in the current locale. A future schema-level
          # default_key would remove the ambiguity with user-created categories.
          i18n_keys = DEFAULT_CATEGORY_TRANSLATION_KEYS.index_with { |key| "models.category.defaults.#{key}" }
          i18n_keys["uncategorized"] = UNCATEGORIZED_NAME_KEY
          i18n_keys["other_investments"] = OTHER_INVESTMENTS_NAME_KEY
          i18n_keys["investment_contributions"] = INVESTMENT_CONTRIBUTIONS_NAME_KEY

          LanguagesHelper::SUPPORTED_LOCALES.each_with_object({}) do |locale, mapping|
            i18n_keys.each_value do |i18n_key|
              translated_name = I18n.t(i18n_key, locale: locale, default: nil)
              mapping[translated_name.to_s] ||= i18n_key if translated_name.present?
            end
          end
        end
      end

      def default_categories
        [
          [ I18n.t("models.category.defaults.income"),                "#22c55e", "circle-dollar-sign" ],
          [ I18n.t("models.category.defaults.food_and_drink"),        "#f97316", "utensils" ],
          [ I18n.t("models.category.defaults.groceries"),             "#407706", "shopping-bag" ],
          [ I18n.t("models.category.defaults.shopping"),              "#3b82f6", "shopping-cart" ],
          [ I18n.t("models.category.defaults.transportation"),        "#0ea5e9", "bus" ],
          [ I18n.t("models.category.defaults.travel"),                "#2563eb", "plane" ],
          [ I18n.t("models.category.defaults.entertainment"),         "#a855f7", "drama" ],
          [ I18n.t("models.category.defaults.healthcare"),            "#4da568", "pill" ],
          [ I18n.t("models.category.defaults.personal_care"),         "#14b8a6", "scissors" ],
          [ I18n.t("models.category.defaults.home_improvement"),      "#d97706", "hammer" ],
          [ I18n.t("models.category.defaults.mortgage_rent"),         "#b45309", "home" ],
          [ I18n.t("models.category.defaults.utilities"),             "#eab308", "lightbulb" ],
          [ I18n.t("models.category.defaults.subscriptions"),         "#6366f1", "wifi" ],
          [ I18n.t("models.category.defaults.insurance"),             "#0284c7", "shield" ],
          [ I18n.t("models.category.defaults.sports_and_fitness"),    "#10b981", "dumbbell" ],
          [ I18n.t("models.category.defaults.gifts_and_donations"),   "#61c9ea", "hand-helping" ],
          [ I18n.t("models.category.defaults.taxes"),                 "#dc2626", "landmark" ],
          [ I18n.t("models.category.defaults.loan_payments"),         "#e11d48", "credit-card" ],
          [ I18n.t("models.category.defaults.services"),              "#7c3aed", "briefcase" ],
          [ I18n.t("models.category.defaults.fees"),                  "#6b7280", "receipt" ],
          [ I18n.t("models.category.defaults.savings_and_investments"), "#059669", "piggy-bank" ],
          [ investment_contributions_name,                       "#0d9488", "trending-up" ]
        ]
      end
  end

  def inherit_color_from_parent
    self.color = parent.color if subcategory? && parent
  end

  def replace_and_destroy!(replacement)
    transaction do
      transactions.update_all category_id: replacement&.id
      destroy!
    end
  end

  def parent?
    if association(:subcategories).loaded?
      subcategories.any?
    else
      subcategories.exists?
    end
  end

  def subcategory?
    parent_id.present? && parent.present?
  end

  def name_with_parent
    return name unless subcategory?

    parent_name = parent&.name
    parent_name.present? ? "#{parent_name} > #{name}" : name
  end

  def display_name
    self.class.localized_default_name_for(name)
  end

  def display_name_with_parent
    subcategory? ? "#{parent.display_name} > #{display_name}" : display_name
  end

  # Predicate: is this the synthetic "Uncategorized" category?
  def uncategorized?
    !persisted? && name == I18n.t(UNCATEGORIZED_NAME_KEY)
  end

  # Predicate: is this the synthetic "Other Investments" category?
  def other_investments?
    !persisted? && name == I18n.t(OTHER_INVESTMENTS_NAME_KEY)
  end

  # Predicate: is this any synthetic (non-persisted) category?
  def synthetic?
    uncategorized? || other_investments?
  end

  private
    def category_level_limit
      if (subcategory? && parent&.subcategory?) || (parent? && subcategory?)
        errors.add(:parent, "can't have more than 2 levels of subcategories")
      end
    end

    def monetizable_currency
      family.currency
    end
end

# TrueLayer's category data + resolution logic.
#
# Resolution priority (first hit wins):
#   1. transaction_classification[1] (subcategory) — e.g. "Restaurants"
#   2. transaction_classification[0] (parent)      — e.g. "Food & Dining"
#   3. transaction_category enum (whitelist)       — FEE_CHARGE / INTEREST / DIVIDEND
#
# Per TrueLayer docs (https://docs.truelayer.com/docs/transactions):
#   - transaction_classification is only populated for UK / Ireland / France
#     banks and never for transaction_category=CREDIT.
#   - Classification can change over time. Re-sync stability is handled by
#     Account::ProviderImportAdapter via Enrichable#enrich_attribute, which
#     skips locked attributes (user manual edits).
#
# INTEREST is amount-sign-dependent: positive = income, negative = expense.
# All other enum values (PURCHASE / TRANSFER / DEBIT / CREDIT / OTHER /
# UNKNOWN / CHEQUE / CASH / ATM / etc.) carry mechanism, not category, and
# are deliberately not fallbacks.
module Provider::Truelayer::CategoryTaxonomy
  # Each entry's `name` is the literal TrueLayer parent string (used for
  # exact O(1) lookup in find_parent). `aliases` are matched fuzzily against
  # the user's Category names. Subcategory keys are TrueLayer's literal
  # subcategory strings.
  CATEGORIES_MAP = {
    food_and_dining: {
      name: "Food & Dining",
      aliases: [ "food", "dining", "food and drink", "food & drink", "food and dining" ],
      subcategories: {
        "Restaurants"   => { aliases: [ "restaurant", "dining" ] },
        "Coffee shops"  => { aliases: [ "coffee", "cafe" ] },
        "Fast Food"     => { aliases: [ "fast food", "takeout" ] },
        "Bars"          => { aliases: [ "bar", "pub", "alcohol" ] },
        "Catering"      => { aliases: [ "catering" ] },
        "Delivery"      => { aliases: [ "delivery", "takeaway" ] }
      }
    },
    shopping: {
      name: "Shopping",
      aliases: [ "shopping", "retail" ],
      subcategories: {
        "Groceries"               => { aliases: [ "grocery", "supermarket" ] },
        "Clothing"                => { aliases: [ "clothing", "apparel" ] },
        "Electronics & Software"  => { aliases: [ "electronic", "computer", "software" ] },
        "Books"                   => { aliases: [ "book" ] },
        "Home"                    => { aliases: [ "home", "homeware" ] },
        "Hobbies"                 => { aliases: [ "hobby" ] },
        "Pets"                    => { aliases: [ "pet", "pet supply" ] },
        "Sporting Goods"          => { aliases: [ "sporting good", "sport" ] },
        "General"                 => { aliases: [ "shopping", "merchandise" ] }
      }
    },
    entertainment: {
      name: "Entertainment",
      aliases: [ "entertainment", "recreation" ],
      subcategories: {
        "Movies & DVDs"         => { aliases: [ "movie", "streaming", "dvd" ] },
        "Music"                 => { aliases: [ "music", "concert" ] },
        "Games"                 => { aliases: [ "game", "gaming" ] },
        "Sport"                 => { aliases: [ "sport", "event" ] },
        "Arts"                  => { aliases: [ "art", "museum" ] },
        "Newspaper & Magazines" => { aliases: [ "newspaper", "magazine" ] },
        "Social Club"           => { aliases: [ "club" ] },
        "Dating"                => { aliases: [ "dating" ] }
      }
    },
    auto_and_transport: {
      name: "Auto & Transport",
      aliases: [ "transportation", "transport", "auto and transport" ],
      subcategories: {
        "Gas & Fuel"           => { aliases: [ "gas", "fuel", "petrol" ] },
        "Parking"              => { aliases: [ "parking" ] },
        "Public transport"     => { aliases: [ "transit", "bus", "train" ] },
        "Taxi"                 => { aliases: [ "taxi", "rideshare" ] },
        "Auto Insurance"       => { aliases: [ "auto insurance", "car insurance" ] },
        "Auto Payment"         => { aliases: [ "auto payment", "car payment" ] },
        "Service & Auto Parts" => { aliases: [ "auto repair", "mechanic", "service" ] },
        "Rental Car & Taxi"    => { aliases: [ "rental car" ] }
      }
    },
    travel: {
      name: "Travel",
      aliases: [ "travel", "vacation", "trip" ],
      subcategories: {
        "Air Travel"        => { aliases: [ "flight", "airfare", "air travel" ] },
        "Hotel"             => { aliases: [ "hotel", "lodging" ] },
        "Vacation"          => { aliases: [ "vacation", "holiday" ] },
        "Rental Car & Taxi" => { aliases: [ "rental car" ] }
      }
    },
    bills_and_utilities: {
      name: "Bills & Utilities",
      aliases: [ "utilities", "bills", "bills and utilities" ],
      subcategories: {
        "Internet"     => { aliases: [ "internet", "broadband" ] },
        "Mobile Phone" => { aliases: [ "mobile", "phone", "cell" ] },
        "Home Phone"   => { aliases: [ "telephone", "landline" ] },
        "Television"   => { aliases: [ "tv", "television", "cable" ] },
        "Utilities"    => { aliases: [ "utility", "electric", "gas", "water" ] }
      }
    },
    home: {
      name: "Home",
      aliases: [ "home", "house", "mortgage", "rent", "mortgage and rent", "mortgage / rent" ],
      subcategories: {
        "Rent"          => { aliases: [ "rent", "lease" ] },
        "Mortgage"      => { aliases: [ "mortgage", "home loan" ] },
        "Secured loans" => { aliases: [ "secured loan" ] }
      }
    },
    health_and_fitness: {
      name: "Health & Fitness",
      aliases: [ "health", "healthcare", "fitness", "health and fitness", "sports and fitness" ],
      subcategories: {
        "Doctor"   => { aliases: [ "doctor", "medical" ] },
        "Dentist"  => { aliases: [ "dental", "dentist" ] },
        "Eye care" => { aliases: [ "eye", "optometrist" ] },
        "Pharmacy" => { aliases: [ "pharmacy", "prescription" ] },
        "Gym"      => { aliases: [ "gym", "fitness", "exercise" ] },
        "Sports"   => { aliases: [ "sport" ] },
        "Pets"     => { aliases: [ "vet", "veterinary" ] }
      }
    },
    personal_care: {
      name: "Personal Care",
      aliases: [ "personal care", "grooming" ],
      subcategories: {
        "Hair"          => { aliases: [ "hair", "salon" ] },
        "Beauty"        => { aliases: [ "beauty", "cosmetic" ] },
        "Spa & Massage" => { aliases: [ "spa", "massage" ] },
        "Laundry"       => { aliases: [ "laundry", "dry cleaning" ] }
      }
    },
    education: {
      name: "Education",
      aliases: [ "education" ],
      subcategories: {
        "Tuition"          => { aliases: [ "tuition", "school" ] },
        "Student Loan"     => { aliases: [ "student loan" ] },
        "Books & Supplies" => { aliases: [ "textbook", "school supplies" ] }
      }
    },
    fees_and_charges: {
      name: "Fees & Charges",
      aliases: [ "fee", "charge", "fees", "fees and charges" ],
      subcategories: {
        "Service Fee"    => { aliases: [ "service fee" ] },
        "Late Fee"       => { aliases: [ "late fee" ] },
        "Finance Charge" => { aliases: [ "finance charge", "interest charge" ] },
        "ATM Fee"        => { aliases: [ "atm fee" ] },
        "Bank Fee"       => { aliases: [ "bank fee" ] },
        "Commissions"    => { aliases: [ "commission" ] }
      }
    },
    taxes: {
      name: "Taxes",
      aliases: [ "tax", "taxes" ],
      subcategories: {
        "Federal Tax"  => { aliases: [ "federal tax" ] },
        "State Tax"    => { aliases: [ "state tax" ] },
        "Local Tax"    => { aliases: [ "local tax", "council tax" ] },
        "Sales Tax"    => { aliases: [ "sales tax", "vat" ] },
        "Property Tax" => { aliases: [ "property tax" ] }
      }
    },
    gifts_and_donations: {
      name: "Gifts & Donations",
      aliases: [ "gift", "donation", "gifts and donations", "gifts & donations" ],
      subcategories: {
        "Gift"    => { aliases: [ "gift" ] },
        "Charity" => { aliases: [ "charity", "donation" ] }
      }
    },
    investments: {
      name: "Investments",
      aliases: [ "investment", "savings and investments", "savings & investments" ],
      subcategories: {
        "Equities"      => { aliases: [ "equity", "stock", "shares" ] },
        "Bonds"         => { aliases: [ "bond" ] },
        "Bank products" => { aliases: [ "savings", "isa" ] },
        "Retirement"    => { aliases: [ "retirement", "pension" ] },
        "Real-estate"   => { aliases: [ "real estate", "property" ] }
      }
    },
    pensions_and_insurances: {
      name: "Pensions and Insurances",
      aliases: [ "insurance", "pension" ],
      subcategories: {
        "Pension payments"                 => { aliases: [ "pension" ] },
        "Life insurance"                   => { aliases: [ "life insurance" ] },
        "Buildings and contents insurance" => { aliases: [ "buildings insurance", "contents insurance", "home insurance" ] },
        "Health insurance"                 => { aliases: [ "health insurance" ] }
      }
    }
  }.freeze

  ENUM_FALLBACK = {
    "FEE_CHARGE" => { aliases: [ "fee", "charge" ], parent_aliases: [ "fee", "fees and charges" ] },
    "DIVIDEND"   => { aliases: [ "dividend" ],      parent_aliases: [ "income" ] }
  }.freeze

  def self.resolve(transaction)
    return nil if transaction.blank?

    classification = transaction[:transaction_classification] || transaction["transaction_classification"]
    if classification.is_a?(Array) && classification.any?
      sub_resolved = resolve_subcategory(classification[0], classification[1])
      return sub_resolved if sub_resolved
      parent_resolved = resolve_parent(classification[0])
      return parent_resolved if parent_resolved
    end

    enum   = transaction[:transaction_category] || transaction["transaction_category"]
    amount = transaction[:amount]               || transaction["amount"]
    resolve_enum(enum, amount)
  end

  def self.resolve_subcategory(parent_name, subcategory_name)
    return nil if parent_name.blank? || subcategory_name.blank?
    parent_data = find_parent(parent_name)
    return nil unless parent_data
    sub_data = parent_data[:subcategories][subcategory_name]
    return nil unless sub_data
    {
      aliases:        sub_data[:aliases],
      parent_aliases: parent_data[:aliases]
    }
  end

  def self.resolve_parent(parent_name)
    return nil if parent_name.blank?
    parent_data = find_parent(parent_name)
    return nil unless parent_data
    {
      aliases:        parent_data[:aliases],
      parent_aliases: parent_data[:aliases]
    }
  end

  def self.resolve_enum(enum, amount)
    return nil if enum.blank?
    case enum.to_s.upcase
    when "INTEREST"
      if amount.to_f >= 0
        { aliases: [ "interest", "interest earned" ], parent_aliases: [ "income" ] }
      else
        { aliases: [ "interest charge", "finance charge" ], parent_aliases: [ "fee", "fees and charges" ] }
      end
    when "FEE_CHARGE", "DIVIDEND"
      ENUM_FALLBACK[enum.to_s.upcase]
    end
  end

  def self.find_parent(parent_name)
    return nil if parent_name.blank?
    CATEGORIES_MAP.values.find { |data| data[:name].casecmp?(parent_name) }
  end

  private_class_method :resolve_subcategory, :resolve_parent, :resolve_enum, :find_parent
end

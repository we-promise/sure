# Maps Merchant Category Codes (ISO 18245) onto the family's existing Sure categories.
#
# Monobank does not categorise transactions; it reports the merchant's MCC (`mcc`, plus
# `originalMcc` when the acquirer rewrote it). That is a far coarser signal than a
# provider-assigned category, so the table below is deliberately conservative: only
# codes whose meaning maps cleanly onto one of Sure's default categories are listed.
#
# Codes with no honest Sure equivalent are intentionally absent, and that includes ones
# it would be tempting to guess at:
#
# * 6011 / 6012 / 4829 / 6051 — cash withdrawals, transfers and quasi-cash. These are
#   money movement, not spending; Sure's transfer matcher pairs them up instead.
# * 5921 / 5993 / 7995 — alcohol, tobacco and gambling, which most people track under
#   their own categories if at all.
# * 8211 / 8220 — education, which has no Sure default category.
#
# A wrong auto-category is worse than none: the import adapter applies matches via
# enrich_attribute, so anything left unmapped simply stays uncategorised for the user's
# own rules (or the AI categoriser) to handle.
module MonobankAccount::Transactions::CategoryTaxonomy
  # Each group carries two ways of finding the user's category:
  #
  # * `key` is the Sure default-category translation key
  #   (Category::DEFAULT_CATEGORY_TRANSLATION_KEYS), so the matcher can compare against
  #   the category name as the family actually sees it in their own locale — the common
  #   case for a Monobank user, whose categories are unlikely to be named in English.
  # * `aliases` are English fallbacks, matched case/punctuation-insensitively, which
  #   also cover categories the user renamed or created by hand.
  MCC_GROUPS = [
    {
      key: :groceries,
      aliases: [ "groceries" ],
      # Supermarkets, plus the specialised food retailers (butcher, bakery, dairy).
      mccs: [ 5411, 5422, 5441, 5451, 5462, 5499 ]
    },
    {
      key: :food_and_drink,
      aliases: [ "food and drink", "dining", "restaurants" ],
      # Caterers, restaurants, drinking places and fast food.
      mccs: [ 5811, 5812, 5813, 5814 ]
    },
    {
      key: :transportation,
      aliases: [ "transportation", "transport" ],
      # Local transit, taxis, rail and bus, fuel, parking, repairs and parts.
      mccs: [ 4111, 4112, 4121, 4131, 4789, 5533, 5541, 5542, 7523, 7531, 7534, 7538, 7549 ]
    },
    {
      key: :travel,
      aliases: [ "travel" ],
      # Airlines (3000-3299 are individual carriers), lodging (3500-3999 are individual
      # hotel chains), cruise lines, travel agencies and vehicle rental.
      mccs: [ 4411, 4457, 4511, 4722, 7011, 7512, 7513, 7519 ],
      mcc_ranges: [ 3000..3299, 3500..3999 ]
    },
    {
      key: :entertainment,
      aliases: [ "entertainment" ],
      # Cinemas, theatres, attractions, amusement parks and recreation services.
      mccs: [ 7832, 7911, 7922, 7929, 7991, 7993, 7994, 7996, 7998, 7999 ]
    },
    {
      key: :healthcare,
      aliases: [ "healthcare", "health" ],
      # Pharmacies, doctors, dentists, hospitals, labs and other medical services.
      mccs: [ 5912, 5975, 5976, 8011, 8021, 8031, 8041, 8042, 8043, 8049, 8050, 8062, 8071, 8099 ]
    },
    {
      key: :personal_care,
      aliases: [ "personal care" ],
      # Barbers and salons, massage, spas and cosmetics retail.
      mccs: [ 5977, 7230, 7297, 7298 ]
    },
    {
      key: :sports_and_fitness,
      aliases: [ "sports and fitness", "fitness" ],
      # Sporting goods, sports clubs and fields, membership (gym) clubs.
      mccs: [ 5941, 7941, 7997 ]
    },
    {
      key: :shopping,
      aliases: [ "shopping" ],
      # General merchandise, clothing and footwear, electronics, furniture, hobby and
      # stationery retail.
      mccs: [
        5300, 5310, 5311, 5399, 5611, 5621, 5631, 5641, 5651, 5655, 5661, 5691, 5699,
        5712, 5713, 5714, 5719, 5722, 5732, 5733, 5734, 5735, 5931, 5942, 5943, 5945,
        5946, 5948, 5949, 5950, 5970, 5999
      ]
    },
    {
      key: :home_improvement,
      aliases: [ "home improvement" ],
      # Building materials, hardware, garden centres and the building trades.
      mccs: [ 1520, 1711, 1731, 1740, 1750, 1761, 1771, 5200, 5211, 5231, 5251, 5261 ]
    },
    {
      key: :utilities,
      aliases: [ "utilities" ],
      # Utilities, and telecom services (a mobile bill is the common case here).
      mccs: [ 4812, 4813, 4814, 4900 ]
    },
    {
      key: :subscriptions,
      aliases: [ "subscriptions" ],
      # Digital media (books, films, music) sold as downloads or subscriptions.
      mccs: [ 5815 ]
    },
    {
      key: :insurance,
      aliases: [ "insurance" ],
      mccs: [ 5960, 6300 ]
    },
    {
      key: :mortgage_rent,
      aliases: [ "mortgage rent", "rent", "mortgage" ],
      # Real estate agents and property managers, i.e. rent payments.
      mccs: [ 6513 ]
    },
    {
      key: :gifts_and_donations,
      aliases: [ "gifts and donations", "donations", "charity" ],
      mccs: [ 8398 ]
    },
    {
      key: :taxes,
      aliases: [ "taxes", "tax" ],
      mccs: [ 9311 ]
    },
    {
      key: :services,
      aliases: [ "services" ],
      # Couriers and post, laundry and dry cleaning, photography, repairs, funeral,
      # legal, accounting, consulting and other professional services.
      mccs: [
        4215, 7210, 7216, 7217, 7221, 7251, 7261, 7276, 7277, 7299, 7311, 7392, 7393,
        7399, 8111, 8931, 9402
      ]
    }
  ].freeze

  # { 5411 => group } lookup built from MCC_GROUPS. Ranges are expanded once at first
  # use; the whole table is only a few thousand small integer keys.
  def self.group_by_mcc
    @group_by_mcc ||= MCC_GROUPS.each_with_object({}) do |group, map|
      codes = Array(group[:mccs]) + Array(group[:mcc_ranges]).flat_map(&:to_a)

      codes.each { |mcc| map[mcc] ||= group }
    end.freeze
  end

  # The taxonomy group for an MCC, or nil when the code has no confident mapping.
  #
  # @param mcc [Integer, String, nil] Merchant Category Code from a Monobank statement
  def mcc_group(mcc)
    return nil if mcc.blank?

    code = Integer(mcc.to_s, exception: false)
    return nil if code.nil?

    MonobankAccount::Transactions::CategoryTaxonomy.group_by_mcc[code]
  end
end

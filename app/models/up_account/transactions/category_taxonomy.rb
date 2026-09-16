# Up Bank's spending category taxonomy (GET /api/v1/categories): four parent groups
# and ~40 child categories. A transaction references a CHILD slug via
# relationships.category.data.id (e.g. "restaurants-and-cafes"); Up does not tag
# transfers or income.
#
# We map those child slugs onto the family's existing/default Sure categories via
# aliases, mirroring PlaidAccount::Transactions::CategoryTaxonomy. Aliases are written
# in Sure's default-category vocabulary and matched case/punctuation-insensitively.
#
# Up categories with no honest Sure-default equivalent (e.g. Booze, Adult, Pets, Apps
# & Games, Life Admin, Technology) are intentionally left without a mapping alias, so
# they stay uncategorised for the user's own rules / AI to handle. A wrong
# auto-category is worse than none.
module UpAccount::Transactions::CategoryTaxonomy
  CATEGORIES_MAP = {
    "good-life": {
      classification: :expense,
      aliases: [],
      detailed_categories: {
        "restaurants-and-cafes": { classification: :expense, aliases: [ "food and drink", "dining", "restaurants" ] },
        "takeaway":              { classification: :expense, aliases: [ "food and drink", "takeout" ] },
        "tv-and-music":          { classification: :expense, aliases: [ "subscriptions" ] },
        "hobbies":               { classification: :expense, aliases: [ "entertainment" ] },
        "events-and-gigs":       { classification: :expense, aliases: [ "entertainment" ] },
        "holidays-and-travel":   { classification: :expense, aliases: [ "travel" ] },
        "pubs-and-bars":         { classification: :expense, aliases: [] },
        "booze":                 { classification: :expense, aliases: [] },
        "games-and-software":    { classification: :expense, aliases: [] },
        "adult":                 { classification: :expense, aliases: [] },
        "lottery-and-gambling":  { classification: :expense, aliases: [] },
        "tobacco-and-vaping":    { classification: :expense, aliases: [] }
      }
    },
    "home": {
      classification: :expense,
      aliases: [],
      detailed_categories: {
        "groceries":                         { classification: :expense, aliases: [ "groceries" ] },
        "utilities":                         { classification: :expense, aliases: [ "utilities" ] },
        "internet":                          { classification: :expense, aliases: [ "utilities" ] },
        "rent-and-mortgage":                 { classification: :expense, aliases: [ "mortgage and rent", "rent" ] },
        "home-maintenance-and-improvements": { classification: :expense, aliases: [ "home improvement" ] },
        "homeware-and-appliances":           { classification: :expense, aliases: [ "shopping" ] },
        "home-insurance-and-rates":          { classification: :expense, aliases: [ "insurance" ] },
        "pets":                              { classification: :expense, aliases: [] }
      }
    },
    "personal": {
      classification: :expense,
      aliases: [],
      detailed_categories: {
        "health-and-medical":          { classification: :expense, aliases: [ "healthcare" ] },
        "fitness-and-wellbeing":       { classification: :expense, aliases: [ "sports and fitness" ] },
        "hair-and-beauty":             { classification: :expense, aliases: [ "personal care" ] },
        "clothing-and-accessories":    { classification: :expense, aliases: [ "shopping" ] },
        "gifts-and-charity":           { classification: :expense, aliases: [ "gifts and donations" ] },
        "investments":                 { classification: :expense, aliases: [ "savings and investments" ] },
        "mobile-phone":                { classification: :expense, aliases: [ "subscriptions" ] },
        "technology":                  { classification: :expense, aliases: [] },
        "life-admin":                  { classification: :expense, aliases: [] },
        "education-and-student-loans": { classification: :expense, aliases: [] },
        "family":                      { classification: :expense, aliases: [] },
        "news-magazines-and-books":    { classification: :expense, aliases: [] }
      }
    },
    "transport": {
      classification: :expense,
      aliases: [ "transportation" ],
      detailed_categories: {
        "fuel":                          { classification: :expense, aliases: [ "transportation" ] },
        "public-transport":              { classification: :expense, aliases: [ "transportation" ] },
        "taxis-and-share-cars":          { classification: :expense, aliases: [ "transportation" ] },
        "parking":                       { classification: :expense, aliases: [ "transportation" ] },
        "toll-roads":                    { classification: :expense, aliases: [ "transportation" ] },
        "cycling":                       { classification: :expense, aliases: [ "transportation" ] },
        "car-insurance-and-maintenance": { classification: :expense, aliases: [ "transportation" ] },
        "car-repayments":                { classification: :expense, aliases: [ "loan payments" ] }
      }
    }
  }.freeze
end

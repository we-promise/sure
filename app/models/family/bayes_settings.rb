# A family's tuning for Family::BayesCategorizer, stored in
# families.bayes_settings. Only values that differ from DEFAULTS are stored,
# so a family that never touched the page follows any later change of a
# default. DEFAULTS reproduce the original categorizer (multinomial NB, add-1,
# uniform prior, words from name, notes and merchant name), so the page
# compares any tuning with it, except that Bayes' own unconfirmed guesses
# don't train it (skip_self_labels).
class Family::BayesSettings
  DEFAULTS = {
    # Training
    excluded_category_ids: [],
    # On: Bayes runs with the rules after every sync, so its own guesses would
    # otherwise train the next run and a wrong one would be reinforced.
    skip_self_labels: true,
    # A guess the user has left alone this long counts as accepted: picking
    # the same category again doesn't lock it, so there's no other way.
    self_label_grace_days: 90,
    exclude_transfers: false,
    # The training set is held in memory, so it's capped; the newest
    # transactions are the most representative of current spending.
    max_training_transactions: 5_000,

    # Words
    include_notes: true,
    # How the text splits into words: a–z and 0–9 only (the original), letters of
    # any script, or any script with symbols inside words kept (CHOICES).
    word_split: "ascii",
    drop_numbers: false,
    keep_single_chars: true,
    drop_codes: false,
    spread_filter: false,
    spread_margin: 0.1,
    bigrams: false,
    merchant_name_words: true,

    # Amount
    amount_field: false,
    amount_by_direction: true,

    # Account and merchant
    account_field: false,
    merchant_field: false,
    # Matcher (the Merchant matcher rule): a missing merchant is copied from
    # near-duplicates (Family::SimilarMerchantFiller) this alike, when at
    # least this many agree. On one family's history 0.8–0.95 made little
    # difference; 2 instead of 1 halved the mistakes, most of them one shop
    # under two merchants.
    lock_similar_merchants: false,
    similar_threshold: 0.9,
    similar_min_neighbours: 2,
    similar_common_share: 0.2,
    # Copying from its own copies, like Bayes' skip_self_labels.
    similar_skip_self: true,
    similar_self_grace_days: 90,

    # Scoring
    complement: false,
    smoothing: 1.0,
    prior: false,
    binary: false,
    separate_fields: false,

    # Classifier (the Category classifier rule)
    threshold: 0.7,
    lock_results: false
  }.freeze

  CHOICES = { word_split: %w[ascii unicode symbols] }.freeze
  # The matcher's similarities and cutoffs scored in Auto-tune, and the
  # numbers agreeing its table and the Merchant matcher tuning section offer.
  STEPS = {
    similar_threshold: [ 0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9, 0.95 ],
    similar_min_neighbours: [ 1, 2, 3 ],
    similar_common_share: [ 0.01, 0.02, 0.05, 0.1, 0.2, 0.4 ]
  }.freeze

  RANGES = {
    self_label_grace_days: 1..3650,
    similar_self_grace_days: 1..3650,
    max_training_transactions: 100..20_000,
    threshold: 0.05..0.99,
    spread_margin: 0.0..0.9,
    smoothing: 0.001..10.0,
    similar_threshold: 0.5..0.99,
    similar_min_neighbours: 1..3,
    similar_common_share: 0.01..1.0
  }.freeze

  attr_reader :values

  def initialize(stored = {})
    stored = (stored || {}).to_h.transform_keys(&:to_sym).slice(*DEFAULTS.keys)
    @values = DEFAULTS.merge(stored.to_h { |key, value| [ key, coerce(key, value) ] }).freeze
  end

  DEFAULTS.each_key { |key| define_method(key) { values[key] } }

  # What goes in the column: only the differences from DEFAULTS.
  def to_stored
    values.reject { |key, value| value == DEFAULTS[key] }.transform_keys(&:to_s)
  end

  def merge(changes)
    self.class.new(values.merge(changes.to_h.transform_keys(&:to_sym)))
  end

  def default?
    to_stored.empty?
  end

  # Short and stable: keys an evaluation result and each Bayes label.
  def digest
    Digest::SHA256.hexdigest(to_stored.sort.to_json)[0, 12]
  end

  private
    def coerce(key, value)
      case DEFAULTS[key]
      when true, false then ActiveModel::Type::Boolean.new.cast(value) ? true : false
      when Array then Array(value).map(&:to_s).reject(&:blank?).uniq.sort
      when Integer then clamp(key, Integer(value.to_s, exception: false) || DEFAULTS[key])
      when Float then clamp(key, Float(value.to_s, exception: false) || DEFAULTS[key])
      when String then CHOICES[key].include?(value.to_s) ? value.to_s : DEFAULTS[key]
      end
    end

    def clamp(key, value)
      RANGES[key] ? value.clamp(RANGES[key].min, RANGES[key].max) : value
    end
end

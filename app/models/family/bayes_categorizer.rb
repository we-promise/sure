# Naive-Bayes transaction categorizer.
#
# Trains a naive-Bayes model on the family's already-categorized transactions
# and classifies uncategorized ones. By default it is the original model:
# multinomial NB over the words of name, notes and merchant name, add-1
# smoothing, uniform prior. Every choice is tunable per family
# (Family::BayesSettings, Settings → Classifier), up to complement NB (Rennie
# et al. 2003, Lidstone smoothing) scoring each transaction as
#   P(c) × P(words | c) × P(merchant | c) × P(account | c)
#        × P(direction | c) × N(log10|amount| ; c, direction, currency)
# with every factor its own distribution, so a long description doesn't
# outweigh the merchant, account or amount. Unlike AutoCategorizer it
# needs no provider — pure Ruby, trained on the fly and memoized per instance.
class Family::BayesCategorizer
  DIRECTIONS = %w[in out].freeze
  # The original guard: no classifying until there's a real signal to train on.
  MIN_TRAINING_TRANSACTIONS = 20
  MIN_CATEGORIES = 2
  # Distance from a mean counts up to this many standard deviations, so a
  # one-off amount can tip a close call but not outvote the merchant.
  AMOUNT_MAX_Z = 3.0
  # A category's amount spread is shrunk towards the overall spread as if it
  # had this many extra observations of it.
  AMOUNT_VARIANCE_SHRINK = 2.0
  # Floor for an amount spread (log10 units squared), so a category whose
  # amounts are all the same doesn't get a zero-width curve.
  AMOUNT_MIN_VARIANCE = 0.001
  # Stored with each label beside the settings digest, so labels from
  # different code can be told apart; the digest identifies the tuning.
  MODEL_VERSION = "bayes-2"

  # Letter/digit runs joined by single symbols stay one token: "mcdonald's",
  # "s/o", "m&s"; leading and trailing symbols ("*netflix") are still stripped.
  KEEP_SYMBOLS = /[\p{L}\p{N}]+(?:[^\p{L}\p{N}\s][\p{L}\p{N}]+)*/
  # Letters mixed with 2+ digits: reference codes like "2k4l19"; keeps "7eleven", "o2".
  CODE = /\A(?=.*\p{L})(?=(?:.*\p{N}){2})/

  # categorized_ids: transaction ids the model labeled at/above threshold
  # (regardless of whether the write actually changed anything).
  # modified_count: how many of those writes changed the category.
  Result = Data.define(:categorized_ids, :modified_count)

  attr_reader :settings

  # as_of: train only on transactions dated on or before it (the time-split
  # evaluation passes the day before each month); without it, on all of them,
  # as the original does.
  def initialize(family, settings: nil, as_of: nil)
    @family = family
    @settings = settings || family.bayes_settings_object
    @as_of = as_of
  end

  # Guard: refuse to classify until there's a real signal to train on.
  def enough_training_data?
    return @enough_training_data if defined?(@enough_training_data)

    @enough_training_data = training_transactions.size >= MIN_TRAINING_TRANSACTIONS &&
      class_models.size >= MIN_CATEGORIES
  end

  # Returns [category_id, confidence] for the argmax category, or nil when
  # the model isn't trained yet or no category clears the confidence
  # threshold (below threshold = no confident answer).
  def classify(transaction)
    category_id, confidence = probabilities(transaction).max_by { |_, probability| probability }
    return nil if category_id.nil? || confidence < settings.threshold

    [ category_id, confidence ]
  end

  # { category_id => softmax score } over every trained category; empty when
  # the model isn't trained yet or nothing about the transaction is known.
  def probabilities(transaction)
    return {} unless enough_training_data?

    log_scores = log_scores_for(transaction)
    log_scores.keys.zip(softmax(log_scores.values)).to_h
  end

  # The categories it can answer with; none until trained.
  def category_ids
    enough_training_data? ? class_models.keys : []
  end

  # Labels every uncategorized, enrichable transaction in transaction_ids
  # whose argmax confidence clears the threshold.
  # No-op (empty Result) when the training guard fails.
  def classify_and_apply(transaction_ids)
    return Result.new(categorized_ids: [], modified_count: 0) unless enough_training_data?

    categorized_ids = []
    modified_count = 0

    scope = family.transactions.where(id: transaction_ids, category_id: nil).enrichable(:category_id)
    scope.includes(*preloads).find_each do |transaction|
      category_id, confidence = classify(transaction)
      next if category_id.nil?

      categorized_ids << transaction.id
      # Kept on the enrichment so the threshold can be audited against what
      # users later changed. A ranking score, not a probability.
      metadata = { confidence: confidence.round(3), model: MODEL_VERSION, settings: settings.digest }
      metadata[:locked_by_bayes] = true if settings.lock_results
      was_modified = transaction.enrich_attribute(:category_id, category_id, source: "bayes", metadata: metadata)
      transaction.lock_attr!(:category_id) if settings.lock_results
      modified_count += 1 if was_modified
    end

    Result.new(categorized_ids: categorized_ids, modified_count: modified_count)
  end

  # An excluded parent takes its subcategories with it.
  def excluded_category_ids
    @excluded_category_ids ||= begin
      ids = settings.excluded_category_ids
      ids.any? ? ids | family.categories.where(parent_id: ids).pluck(:id).map(&:to_s) : ids
    end
  end

  private
    attr_reader :family, :as_of

    def preloads
      settings.merchant_name_words ? %i[entry merchant] : %i[entry]
    end

    # Words from the entry (and optionally merchant name), the merchant by id
    # and the account. Binary counts each token once per transaction.
    def tokens_for(transaction)
      tokens = word_tokens(transaction)
      tokens << "merchant:#{transaction.merchant_id}" if settings.merchant_field && transaction.merchant_id
      tokens << "account:#{transaction.entry.account_id}" if settings.account_field
      settings.binary ? tokens.uniq : tokens
    end

    def word_tokens(transaction)
      entry = transaction.entry
      parts = [ entry.name ]
      parts << entry.notes if settings.include_notes
      parts << transaction.merchant&.name if settings.merchant_name_words
      text = parts.compact.join(" ").downcase

      tokens = case settings.word_split
      when "symbols" then text.scan(KEEP_SYMBOLS)
      when "unicode" then text.scan(/[\p{L}\p{N}]+/)
      else text.scan(/[a-z0-9]+/)
      end
      if settings.drop_numbers
        # With symbols kept, "12.50" or "16/10/2026" aren't all-digit: drop
        # any token without a letter instead.
        tokens = tokens.reject { |token| settings.word_split == "symbols" ? !token.match?(/\p{L}/) : token.match?(/\A\p{N}+\z/) }
      end
      tokens = tokens.reject { |token| token.length < 2 } unless settings.keep_single_chars
      tokens = tokens.reject { |token| token.match?(CODE) } if settings.drop_codes
      tokens += tokens.each_cons(2).map { |a, b| "#{a} #{b}" } if settings.bigrams
      tokens
    end

    # Only "merchant:" and "account:" tokens carry these prefixes; a word can
    # contain ":" only when split with symbols, and never starts this way in practice.
    def field_for(token)
      return :all unless settings.separate_fields

      if token.start_with?("merchant:") then :merchant
      elsif token.start_with?("account:") then :account
      else :words
      end
    end

    def direction_for(transaction)
      transaction.entry.amount.negative? ? "in" : "out"
    end

    def log_amount(transaction)
      Math.log10([ transaction.entry.amount.abs.to_f, 0.01 ].max)
    end

    # The newest categorized transactions by creation (as the original), dated on
    # or before as_of if given, minus excluded categories, and
    # optionally minus Bayes' own labels still waiting to be confirmed, so a
    # wrong guess isn't fed back in and reinforced. A label trains once
    # someone changes or locks it, or after its grace period.
    def training_transactions
      @training_transactions ||= begin
        scope = family.transactions.where.not(category_id: nil).joins(:entry)
        scope = scope.where(entries: { date: ..as_of }) if as_of
        scope = scope.where.not(category_id: excluded_category_ids) if excluded_category_ids.any?
        scope = scope.where.not(kind: Transaction::TRANSFER_KINDS) if settings.exclude_transfers
        scope = scope.where.not(unconfirmed_self_label_sql) if settings.skip_self_labels
        scope.preload(*preloads)
             .order("transactions.created_at DESC, transactions.id DESC")
             .limit(settings.max_training_transactions)
             .to_a
      end
    end

    # The category is still Bayes' recent guess. A lock the user set confirms
    # it; one Bayes set itself (lock_results) doesn't.
    def unconfirmed_self_label_sql
      "#{Transaction.category_from_sql("bayes", since: settings.self_label_grace_days.days.ago)} " \
        "AND (NOT (transactions.locked_attributes ? 'category_id') " \
        "OR #{Transaction.category_from_sql("bayes", metadata: { locked_by_bayes: true })})"
    end

    # { category_id => { counts: { token => n }, field_totals: { field => n }, docs: n, total: n } }
    def class_models
      @class_models ||= training_transactions.group_by(&:category_id).transform_values do |txns|
        counts = Hash.new(0)
        txns.each { |txn| tokens_for(txn).each { |token| counts[token] += 1 } }
        field_totals = Hash.new(0)
        counts.each { |token, count| field_totals[field_for(token)] += count }
        { counts: counts, field_totals: field_totals, docs: txns.size, total: counts.values.sum }
      end
    end

    # P(c): the category's share of the training transactions, so a close
    # call leans towards the category used more often; or uniform.
    def log_prior(category_id)
      return Math.log(1.0 / class_models.size) unless settings.prior

      Math.log(class_models.fetch(category_id)[:docs].to_f / training_transactions.size)
    end

    # Token counts over every category, for the complements; its keys are the
    # vocabulary.
    def all_counts
      @all_counts ||= class_models.values.each_with_object(Hash.new(0)) do |model, sums|
        model[:counts].each { |token, count| sums[token] += count }
      end
    end

    def all_field_totals
      @all_field_totals ||= class_models.values.each_with_object(Hash.new(0)) do |model, sums|
        model[:field_totals].each { |field, count| sums[field] += count }
      end
    end

    def field_vocabulary_sizes
      @field_vocabulary_sizes ||= all_counts.keys.each_with_object(Hash.new(0)) { |token, sizes| sizes[field_for(token)] += 1 }
    end

    # Known tokens that can count as evidence. With the spread filter, a word
    # (or merchant) used at much the same rate by every category is ignored:
    # it counts only if one category's share of its rate is at least
    # 1/K + spread_margin (from Bishop/Reverend). Accounts are exempt.
    def usable_tokens
      @usable_tokens ||= if settings.spread_filter
        even = 1.0 / class_models.size
        all_counts.keys.select do |token|
          next true if token.start_with?("account:")

          rates = class_models.values.map { |model| model[:total].zero? ? 0.0 : model[:counts][token].to_f / model[:total] }
          rates.max / rates.sum >= even + settings.spread_margin
        end.to_set
      else
        all_counts.keys.to_set
      end
    end

    # Complement NB (default): each category is scored by how badly the
    # transaction fits every *other* category, negated, plus the prior. Per
    # token field f:
    #   log P(c) - Σ_tokens log((count_t(¬c) + α) / (total_f(¬c) + α|V_f|)) - log P(amount | ¬c)
    # With two categories it equals multinomial NB, which the complement
    # setting switches to: log P(c) + Σ log P(t | c) + log P(amount | c).
    def log_scores_for(transaction)
      # Unknown tokens carry no signal and are skipped; a transaction needs
      # at least one known word or merchant, as the original, or it's left
      # uncategorized: the account and amount never decide alone.
      known_tokens = tokens_for(transaction).select { |token| usable_tokens.include?(token) }
      return {} if known_tokens.none? { |token| !token.start_with?("account:") }

      class_models.each_with_object({}) do |(category_id, model), scores|
        token_log_likelihood = known_tokens.sum { |token| token_log_likelihood(token, model) }
        amount_log_likelihood = settings.amount_field ? amount_log_likelihood(category_id, transaction) : 0.0
        scores[category_id] = if settings.complement
          log_prior(category_id) - token_log_likelihood - amount_log_likelihood
        else
          log_prior(category_id) + token_log_likelihood + amount_log_likelihood
        end
      end
    end

    def token_log_likelihood(token, model)
      field = field_for(token)
      count = model[:counts][token]
      total = model[:field_totals][field]
      if settings.complement
        count = all_counts[token] - count
        total = all_field_totals[field] - total
      end
      Math.log((count + settings.smoothing) / (total + settings.smoothing * field_vocabulary_sizes[field]))
    end

    def direction_key(transaction)
      settings.amount_by_direction ? direction_for(transaction) : "all"
    end

    # Sufficient statistics [n, Σx, Σx²] of x = log10|amount|, per
    # [category_id, direction] and per direction for P(direction), and the
    # same within each currency for the Gaussian, so ¥5,000 and $5,000 don't
    # share a scale ("all" when that split is off).
    def amount_stats
      @amount_stats ||= training_transactions.each_with_object({}) do |txn, stats|
        x = log_amount(txn)
        direction = direction_key(txn)
        currency = txn.entry.currency
        keys = [ [ txn.category_id, direction ], direction, [ txn.category_id, direction, currency ], [ direction, currency ] ]
        keys.each do |key|
          sums = (stats[key] ||= [ 0, 0.0, 0.0 ])
          sums[0] += 1
          sums[1] += x
          sums[2] += x * x
        end
      end
    end

    def seen_directions
      @seen_directions ||= DIRECTIONS.count { |direction| amount_stats.key?(direction) }
    end

    # log of P(direction | side) × N(log10|amount| ; side, direction,
    # currency), where side is every *other* category for complement NB and
    # the category itself otherwise. Per-direction Gaussians keep refunds and
    # purchases at the same shop apart, and nearby amounts share evidence. 0
    # for a direction never seen in training; no Gaussian for a currency never
    # seen in it. Distance is capped at AMOUNT_MAX_Z standard deviations.
    def amount_log_likelihood(category_id, transaction)
      direction = direction_key(transaction)
      return 0.0 unless amount_stats.key?(direction)

      log_likelihood = 0.0
      if settings.amount_by_direction
        own_count = amount_stats.fetch([ category_id, direction ], [ 0 ])[0]
        own_size = class_models[category_id][:docs]
        count, size = if settings.complement
          [ amount_stats[direction][0] - own_count, training_transactions.size - own_size ]
        else
          [ own_count, own_size ]
        end
        log_likelihood = Math.log((count + settings.smoothing) / (size + settings.smoothing * seen_directions))
      end

      currency = transaction.entry.currency
      all = amount_stats[[ direction, currency ]]
      return log_likelihood unless all

      own = amount_stats.fetch([ category_id, direction, currency ], [ 0, 0.0, 0.0 ])
      side = settings.complement ? all.zip(own).map { |a, o| a - o } : own
      n = side[0]
      return log_likelihood if n <= 0 || all[0] < 2

      overall_variance = [ all[2] / all[0] - (all[1] / all[0])**2, AMOUNT_MIN_VARIANCE ].max
      mean = side[1] / n
      variance = [ side[2] / n - mean**2, 0.0 ].max
      variance = (n * variance + AMOUNT_VARIANCE_SHRINK * overall_variance) / (n + AMOUNT_VARIANCE_SHRINK)
      variance = [ variance, AMOUNT_MIN_VARIANCE ].max
      z = ((log_amount(transaction) - mean) / Math.sqrt(variance)).clamp(-AMOUNT_MAX_Z, AMOUNT_MAX_Z)
      log_likelihood - 0.5 * Math.log(2 * Math::PI * variance) - 0.5 * z**2
    end

    # Numerically stable softmax over the log-scores.
    def softmax(scores)
      max = scores.max
      exps = scores.map { |score| Math.exp(score - max) }
      sum = exps.sum
      exps.map { |exp| exp / sum }
    end
end

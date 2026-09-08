# Naive-Bayes transaction categorizer.
#
# Trains a multinomial naive-Bayes model (Laplace add-1 smoothing) on the
# family's already-categorized transactions, then classifies uncategorized
# ones from the same token signals the LLM categorizer uses
# (entry name + notes + merchant name). Unlike AutoCategorizer it needs no
# provider — pure Ruby, trained on the fly and memoized per instance.
class Family::BayesCategorizer
  CONFIDENCE_THRESHOLD = 0.7
  MIN_TRAINING_TRANSACTIONS = 20
  MIN_CATEGORIES = 2
  # The whole training set is held in memory, so cap it rather than loading a
  # long-lived family's entire history on every categorization run. The most
  # recent transactions are also the most representative of current spending.
  MAX_TRAINING_TRANSACTIONS = 5_000

  # categorized_ids: transaction ids the model labeled at/above threshold
  # (regardless of whether the write actually changed anything).
  # modified_count: how many of those writes changed the category.
  Result = Data.define(:categorized_ids, :modified_count)

  def initialize(family)
    @family = family
  end

  # Guard: refuse to classify until there's a real signal to train on.
  def enough_training_data?
    training_transactions.size >= MIN_TRAINING_TRANSACTIONS &&
      training_transactions.map(&:category_id).uniq.size >= MIN_CATEGORIES
  end

  # Returns [category_id, confidence] for the argmax category, or nil when
  # the model isn't trained yet or no category clears the confidence
  # threshold (below threshold = no confident answer).
  def classify(transaction)
    return nil unless enough_training_data?

    log_scores = log_scores_for(tokens_for(transaction))
    return nil if log_scores.empty?

    category_id, _score = log_scores.max_by { |_, score| score }
    confidence = softmax(log_scores.values).max
    return nil if confidence < CONFIDENCE_THRESHOLD

    [ category_id, confidence ]
  end

  # Labels every uncategorized, enrichable transaction in transaction_ids
  # whose argmax confidence clears the threshold. No-op (empty Result) when
  # the training guard fails.
  def classify_and_apply(transaction_ids)
    return Result.new(categorized_ids: [], modified_count: 0) unless enough_training_data?

    categorized_ids = []
    modified_count = 0

    family.transactions
          .where(id: transaction_ids, category_id: nil)
          .enrichable(:category_id)
          .includes(:category, :merchant, :entry)
          .find_each do |transaction|
      category_id, _confidence = classify(transaction)
      next if category_id.nil?

      categorized_ids << transaction.id
      was_modified = transaction.enrich_attribute(:category_id, category_id, source: "bayes")
      modified_count += 1 if was_modified
    end

    Result.new(categorized_ids: categorized_ids, modified_count: modified_count)
  end

  private
    attr_reader :family

    # Same signal composition as AutoCategorizer#transactions_input, so the
    # two categorizers agree on what text a transaction speaks.
    def tokens_for(transaction)
      [ transaction.entry&.name, transaction.entry&.notes, transaction.merchant&.name ]
        .compact
        .join(" ")
        .downcase
        .scan(/[a-z0-9]+/)
    end

    def training_transactions
      @training_transactions ||= family.transactions
                                      .where.not(category_id: nil)
                                      .includes(:category, :merchant, :entry)
                                      .order(created_at: :desc)
                                      .limit(MAX_TRAINING_TRANSACTIONS)
                                      .to_a
    end

    # Per-category token-count models: { category_id => { total:, counts: } }.
    def class_models
      @class_models ||= training_transactions.group_by(&:category_id).transform_values do |txns|
        counts = Hash.new(0)
        txns.each { |txn| tokens_for(txn).each { |token| counts[token] += 1 } }
        { total: counts.values.sum, counts: counts }
      end
    end

    def vocabulary
      @vocabulary ||= class_models.values.flat_map { |model| model[:counts].keys }.uniq
    end

    # Multinomial NB log-score per category with Laplace add-1 smoothing and
    # a uniform prior (constant across classes, so it drops out of softmax).
    # log(P(c)) + Σ_tokens log((count_t + 1) / (total + |V|))
    def log_scores_for(tokens)
      return {} if tokens.empty? || class_models.empty?

      denominator = vocabulary.size
      class_models.each_with_object({}) do |(category_id, model), scores|
        score = Math.log(1.0 / class_models.size)
        score += tokens.sum do |token|
          count = model[:counts][token] || 0
          Math.log((count + 1).to_f / (model[:total] + denominator))
        end
        scores[category_id] = score
      end
    end

    # Numerically stable softmax over the log-scores.
    def softmax(scores)
      max = scores.max
      exps = scores.map { |score| Math.exp(score - max) }
      sum = exps.sum
      exps.map { |exp| exp / sum }
    end
end

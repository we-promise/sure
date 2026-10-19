# Evaluates Family::BayesCategorizer — the free, local, first stage of the
# categorization cascade that Family#auto_categorize_transactions runs before
# any paid provider sees a transaction.
#
# Bayes is trained per-family on that family's own categorized history, so
# unlike a provider it cannot simply be handed a batch. This materializes a
# throwaway family from the training split — real Categories, Accounts, Entries
# and Transactions — trains the real classifier on it, and classifies the test
# split through the real `#classify`. Nothing about the scoring is
# reimplemented here; a copy would drift from production the first time
# BayesCategorizer changed.
#
# READ THE LIMITATION BEFORE QUOTING ANY NUMBER FROM THIS RUNNER. A golden
# dataset is roughly one transaction per distinct merchant, chosen for coverage.
# A real family's history is the opposite shape: the same handful of merchants
# repeating hundreds of times. Naive Bayes feeds on exactly that repetition, and
# has almost none of it here, so this run is close to a worst case for Bayes and
# very likely understates the coverage it achieves in production. Treat the
# Bayes leg as a lower bound, not a measurement.
class Eval::Runners::BayesRunner < Eval::Runners::CategorizationRunner
  # Marker so a run that dies mid-way leaves something obviously disposable
  # behind rather than a family that looks real.
  FAMILY_NAME_PREFIX = "[eval] bayes fixture".freeze

  def run
    super
  ensure
    destroy_fixture_family
  end

  protected

    def process_samples
      split = sample_split
      log_progress("Split: #{split.describe.to_json}")

      if split.train.empty?
        raise "Bayes evaluation needs a training split; got none. Check split_ratio."
      end

      build_fixture_family(split.train)
      classify_test_samples(split.test)
    end

    # Bayes never uses a provider — it is pure Ruby with no credentials. Guard
    # rather than inherit Base#provider, so a misconfigured run fails loudly
    # instead of trying to build an API client.
    def provider
      raise "Eval::Runners::BayesRunner does not use a provider"
    end

  private

    def categorizer
      @categorizer ||= Family::BayesCategorizer.new(fixture_family)
    end

    def classify_test_samples(test_samples)
      log_progress("Classifying #{test_samples.size} held-out samples")

      unless categorizer.enough_training_data?
        log_progress("Training guard failed — Bayes declines everything, as it would in production")
      end

      test_samples.each do |sample|
        start_time = Time.current
        transaction = build_transaction_for(sample, category: nil)
        classification = categorizer.classify(transaction)
        latency_ms = ((Time.current - start_time) * 1000).to_i

        record_classification(sample, classification, latency_ms)
      end
    end

    def record_classification(sample, classification, latency_ms)
      category_id, confidence = classification
      actual_category = category_id ? category_names_by_id[category_id] : nil
      declined = classification.nil?

      expected_category = sample.expected_category_name
      acceptable = sample.all_acceptable_categories

      # A decline is not an answer of "no category". In the cascade it means
      # "pass this to the next stage", so it is never scored as correct — even
      # for a null-expected sample, where the *cascade* may still end up right
      # once the provider stage answers. Eval::Reporters::CascadeReport is what
      # reads these apart; the headline accuracy on this run is deliberately
      # "share of the test set Bayes resolved correctly on its own".
      correct = if declined
        false
      else
        evaluate_correctness_with_alternatives(actual_category, expected_category, acceptable)
      end

      record_result(
        sample: sample,
        actual_output: { "category_name" => actual_category },
        correct: correct,
        exact_match: !declined && actual_category == expected_category,
        alternative_match: !declined && acceptable.include?(actual_category) && actual_category != expected_category,
        hierarchical_match: declined ? false : evaluate_hierarchical_match(actual_category, expected_category, sample),
        null_expected: expected_category.nil?,
        null_returned: actual_category.nil?,
        latency_ms: latency_ms,
        cost: 0,
        metadata: {
          "declined" => declined,
          "confidence" => confidence
        }.compact
      )
    end

    # --- fixture construction -------------------------------------------------

    def fixture_family
      @fixture_family || raise("Fixture family not built yet")
    end

    def build_fixture_family(train_samples)
      @fixture_family = Family.create!(name: "#{FAMILY_NAME_PREFIX} #{eval_run.id}")
      @fixture_account = @fixture_family.accounts.create!(
        name: "Eval account",
        balance: 0,
        currency: "USD",
        accountable: Depository.new
      )

      build_categories
      train_samples.each { |sample| build_transaction_for(sample, category: category_for(sample)) }

      log_progress(
        "Fixture family: #{@fixture_family.categories.count} categories, " \
        "#{train_samples.size} training transactions"
      )
    end

    # Built from the dataset's own category context so the names Bayes can
    # return match the names the expectations are written against.
    def build_categories
      context = samples_context
      created = {}

      # Parents first: a subcategory's parent_id has to resolve to a real row.
      context.sort_by { |category| category["parent_id"].present? ? 1 : 0 }.each do |category|
        created[category["id"].to_s] = fixture_family.categories.create!(
          name: category["name"],
          parent: created[category["parent_id"].to_s]
        )
      end

      @categories_by_context_id = created
    end

    def samples_context
      eval_run.dataset.samples.first&.categories_context || []
    end

    def categories_by_context_id
      @categories_by_context_id ||= {}
    end

    def category_names_by_id
      @category_names_by_id ||= categories_by_context_id.values.index_by(&:id).transform_values(&:name)
    end

    def category_for(sample)
      categories_by_context_id.values.find { |category| category.name == sample.expected_category_name }
    end

    # Mirrors Family::AutoCategorizer#transactions_input: the description is the
    # entry name plus notes, and the merchant is a separate signal. Bayes reads
    # exactly those three fields, so building them any other way would evaluate
    # a different input than production sees.
    def build_transaction_for(sample, category:)
      input = sample.to_transaction_input

      entry = @fixture_account.entries.create!(
        name: input[:description].to_s,
        date: Date.current,
        currency: "USD",
        amount: input[:amount] || 0,
        entryable: Transaction.new(
          category: category,
          merchant: merchant_for(input[:merchant])
        )
      )

      entry.entryable
    end

    def merchant_for(name)
      return nil if name.blank?

      @merchants ||= {}
      @merchants[name] ||= fixture_family.merchants.find_or_create_by!(name: name)
    end

    def destroy_fixture_family
      @fixture_family&.destroy
      @fixture_family = nil
    rescue => e
      # A leaked fixture family is untidy but not worth failing a completed run
      # over; the marker prefix makes it findable.
      Rails.logger.warn("[Eval::Runner] Failed to clean up Bayes fixture family: #{e.class}: #{e.message}")
    end
end

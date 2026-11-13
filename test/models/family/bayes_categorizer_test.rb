require "test_helper"

class Family::BayesCategorizerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  # The hand-worked tests below are for a model tuned on one family's
  # history; the original model has its own test.
  TUNED = {
    # A wrong guess isn't fed back in and reinforced.
    skip_self_labels: true,
    # Softmax over complement scores is a ranking score, not a probability.
    threshold: 0.4,
    word_split: "unicode",
    # Digit tokens bloated the vocabulary and inflated confidence.
    drop_numbers: true,
    # The merchant counts by id instead, so its name isn't double-counted.
    merchant_name_words: false,
    amount_field: true,
    account_field: true,
    merchant_field: true,
    # Complement NB with Lidstone 0.1 beat add-1 and 0.5.
    complement: true,
    smoothing: 0.1,
    prior: true,
    separate_fields: true
  }.freeze

  setup do
    # Fresh family: fixture families carry categorized transactions (e.g.
    # dylan_family's "Starbucks"/"Amazon" → Food & Drink) that would pollute
    # the training set and break the hand-worked 2-category math below.
    @family = Family.create!(name: "Bayes Family")
    @account = @family.accounts.create!(name: "Bayes test", balance: 100, currency: "USD", accountable: Depository.new)
    @coffee = @family.categories.create!(name: "Coffee")
    @groceries = @family.categories.create!(name: "Groceries")
    @starbucks = @family.merchants.create!(name: "Starbucks")
    @safeway = @family.merchants.create!(name: "Safeway")
    @family.update_bayes_settings!(TUNED)
  end

  # 10 coffee + 10 groceries = 20 categorized txns over 2 categories, so the
  # training guard passes. Every txn has the same account, direction and
  # amount. Words field: { starbucks, coffee, safeway, groceries },
  # |V_words| = 4, 20 word tokens per class (10 txns x 2).
  def train_two_categories
    10.times { create_transaction(account: @account, name: "Starbucks Coffee", category: @coffee) }
    10.times { create_transaction(account: @account, name: "Safeway Groceries", category: @groceries) }
  end

  def tuned(**changes)
    Family::BayesCategorizer.new(@family, settings: Family::BayesSettings.new(TUNED.merge(changes)))
  end

  test "the defaults are the original model: add-1 multinomial, uniform prior, merchant name as words" do
    train_two_categories
    categorizer = Family::BayesCategorizer.new(@family, settings: Family::BayesSettings.new)

    category_id, confidence = categorizer.classify(create_transaction(account: @account, name: "Starbucks Coffee").transaction)

    # The original's own hand-worked case: 2 × ln(11/24) against 2 × ln(1/24),
    # softmax ≈ 0.9918.
    assert_equal @coffee.id, category_id
    assert_in_delta 0.9918, confidence, 0.001
    assert_equal @coffee.id, categorizer.classify(create_transaction(account: @account, name: "Purchase", merchant: @starbucks).transaction)&.first
    assert_nil categorizer.classify(create_transaction(account: @account, name: "Zzyzx Blorptronics").transaction)
    assert_equal 0.7, categorizer.settings.threshold
  end

  test "no-op before enough training data" do
    categorizer = Family::BayesCategorizer.new(@family)

    assert_not categorizer.enough_training_data?

    5.times { create_transaction(account: @account, name: "Starbucks Coffee", category: @coffee) }

    assert_not categorizer.enough_training_data?
    uncategorized = create_transaction(account: @account, name: "Starbucks Coffee")

    assert_nil categorizer.classify(uncategorized.transaction)
    assert_difference "DataEnrichment.count", 0 do
      result = categorizer.classify_and_apply([ uncategorized.transaction.id ])
      assert_equal [], result.categorized_ids
      assert_equal 0, result.modified_count
    end
    assert_nil uncategorized.transaction.reload.category
  end

  test "separable merchants classify above threshold with hand-worked confidence" do
    train_two_categories
    categorizer = Family::BayesCategorizer.new(@family)
    assert categorizer.enough_training_data?

    txn = create_transaction(account: @account, name: "Starbucks Coffee")

    category_id, confidence = categorizer.classify(txn.transaction)

    assert_equal @coffee.id, category_id

    # Hand-worked complement NB, α = 0.1, prior = share of txns. With two
    # categories each one's complement is the other:
    #   P(coffee) = P(other) = 0.5; words: complement total 20, α|V_words| = 0.4
    #   direction, account and the amount score the same in both and cancel (F)
    #   score_coffee  = ln(0.5) - 2 ln(0.1/20.4)  - F   (groceries never says starbucks/coffee)
    #   score_other   = ln(0.5) - 2 ln(10.1/20.4) - F
    #   softmax(coffee) = 1 / (1 + e^(score_other - score_coffee))
    #                   = 1 / (1 + e^(-2 ln 101)) = 10201/10202 ≈ 0.9999
    assert_in_delta 0.9999, confidence, 0.0001
    assert_operator confidence, :>=, Family::BayesSettings::DEFAULTS[:threshold]
  end

  test "wholly novel tokens stay unclassified even when class corpora are lopsided" do
    # The symmetric fixture above cannot catch this: with equal token totals an
    # unknown token contributes the same smoothed likelihood to every class and
    # the bias cancels. Give one class a much larger corpus and an unseen
    # description would otherwise land on the smaller class with high
    # confidence, purely because 1/(total + |V|) is larger there.
    10.times { create_transaction(account: @account, name: "Starbucks Coffee", category: @coffee) }
    10.times do
      create_transaction(
        account: @account,
        name: "Safeway Groceries Produce Dairy Bakery Deli Frozen Pantry",
        category: @groceries
      )
    end

    categorizer = Family::BayesCategorizer.new(@family)
    assert categorizer.enough_training_data?

    novel = create_transaction(account: @account, name: "Zzyzx Blorptronics")

    assert_nil categorizer.classify(novel.transaction),
      "a description with no known tokens must not be classified from corpus-size bias alone"
  end

  test "training data with no usable tokens classifies nothing" do
    # Degenerate corpus: every training transaction tokenizes to nothing, so the
    # vocabulary is empty. Scoring against a zero-sized vocabulary would divide
    # by a zero token total and produce Infinity, whose softmax is NaN — and NaN
    # fails every comparison, so a threshold check cannot reject it. Guard is
    # that an empty vocabulary leaves no known tokens to score at all.
    10.times { create_transaction(account: @account, name: "---", category: @coffee) }
    10.times { create_transaction(account: @account, name: "...", category: @groceries) }

    categorizer = Family::BayesCategorizer.new(@family)
    assert categorizer.enough_training_data?

    txn = create_transaction(account: @account, name: "Starbucks Coffee")

    assert_nil categorizer.classify(txn.transaction)
    assert_difference "DataEnrichment.count", 0 do
      result = categorizer.classify_and_apply([ txn.transaction.id ])
      assert_equal [], result.categorized_ids
    end
    assert_nil txn.transaction.reload.category
  end

  test "novel merchant below threshold is left alone" do
    train_two_categories
    categorizer = Family::BayesCategorizer.new(@family)

    novel = create_transaction(account: @account, name: "New Shop", merchant: @family.merchants.create!(name: "Unknown Emporium"))

    assert_nil categorizer.classify(novel.transaction)
    assert_difference "DataEnrichment.count", 0 do
      result = categorizer.classify_and_apply([ novel.transaction.id ])
      assert_equal [], result.categorized_ids
      assert_equal 0, result.modified_count
    end
    assert_nil novel.transaction.reload.category
  end

  test "mixed case and merchant signals classify and modified_count sums correctly" do
    train_two_categories
    5.times { create_transaction(account: @account, name: "Card Payment", merchant: @starbucks, category: @coffee) }
    5.times { create_transaction(account: @account, name: "Card Payment", merchant: @safeway, category: @groceries) }
    categorizer = Family::BayesCategorizer.new(@family)

    # Same tokens as "starbucks coffee" — downcase normalization.
    txn1 = create_transaction(account: @account, name: "STARBUCKS Coffee")
    # Name is generic but the merchant carries the signal.
    txn2 = create_transaction(account: @account, name: "Purchase", merchant: @starbucks)
    # Already categorized → outside scope, must not be counted.
    txn3 = create_transaction(account: @account, name: "Safeway Groceries", category: @groceries)

    assert_difference "DataEnrichment.count", 2 do
      result = categorizer.classify_and_apply([ txn1.transaction.id, txn2.transaction.id, txn3.transaction.id ])
      assert_equal [ txn1.transaction.id, txn2.transaction.id ].sort, result.categorized_ids.sort
      assert_equal 2, result.modified_count
    end

    assert_equal @coffee, txn1.transaction.reload.category
    assert_equal @coffee, txn2.transaction.reload.category
    assert_equal @groceries, txn3.transaction.reload.category

    enrichment = txn1.transaction.data_enrichments.find_by(attribute_name: "category_id")
    assert_equal "bayes", enrichment.source
    assert_in_delta 1.0, enrichment.metadata["confidence"], 0.001
    assert_equal Family::BayesCategorizer::MODEL_VERSION, enrichment.metadata["model"]
    assert_equal @family.bayes_settings_object.digest, enrichment.metadata["settings"]
  end

  test "its own unconfirmed labels do not count as training data" do
    train_two_categories
    # 10 more coffee-looking rows that Bayes labels itself.
    guesses = Array.new(10) { create_transaction(account: @account, name: "Starbucks Coffee").transaction }
    Family::BayesCategorizer.new(@family).classify_and_apply(guesses.map(&:id))
    assert guesses.all? { |txn| txn.reload.category == @coffee }

    categorizer = Family::BayesCategorizer.new(@family)
    assert_equal 20, categorizer.send(:training_transactions).size

    # A user correction makes the row training data again.
    guesses.first.update!(category: @groceries)
    assert_equal 21, Family::BayesCategorizer.new(@family).send(:training_transactions).size

    # So does locking the category, or leaving the guess alone long enough.
    guesses.second.lock_attr!(:category_id)
    assert_equal 22, Family::BayesCategorizer.new(@family).send(:training_transactions).size
    travel Family::BayesSettings::DEFAULTS[:self_label_grace_days].days + 1.day do
      assert_equal 30, Family::BayesCategorizer.new(@family).send(:training_transactions).size
    end
  end

  test "non-ASCII descriptions tokenize as whole words" do
    10.times { create_transaction(account: @account, name: "Bäckerei Müller", category: @groceries) }
    10.times { create_transaction(account: @account, name: "Кофейня Шоколадница", category: @coffee) }
    categorizer = Family::BayesCategorizer.new(@family)

    german = create_transaction(account: @account, name: "BÄCKEREI MÜLLER")
    cyrillic = create_transaction(account: @account, name: "КОФЕЙНЯ")

    assert_equal @groceries.id, categorizer.classify(german.transaction)&.first
    assert_equal @coffee.id, categorizer.classify(cyrillic.transaction)&.first
  end

  test "numbers are not tokens" do
    # The card's last-4 appears on every coffee row; it must not let a
    # description with no merchant words land in Coffee.
    10.times { create_transaction(account: @account, name: "Starbucks Coffee 4471", category: @coffee) }
    10.times { create_transaction(account: @account, name: "Safeway Groceries 7eleven", category: @groceries) }
    categorizer = Family::BayesCategorizer.new(@family)

    numbers_only = create_transaction(account: @account, name: "4471")
    mixed = create_transaction(account: @account, name: "7ELEVEN 0012")

    assert_nil categorizer.classify(numbers_only.transaction)
    assert_equal @groceries.id, categorizer.classify(mixed.transaction)&.first
  end

  test "money in or out separates categories the words alone cannot" do
    refunds = @family.categories.create!(name: "Refunds")
    10.times { create_transaction(account: @account, name: "Starbucks Coffee", category: @coffee) }
    15.times { create_transaction(account: @account, name: "Woolworths", category: @groceries) }
    5.times { create_transaction(account: @account, name: "Woolworths Refund", amount: -100, category: refunds) }
    categorizer = Family::BayesCategorizer.new(@family)

    # From the words alone both lean Groceries at ~0.79, so the credit would
    # be filed as Groceries; with money in/out, debit -> Groceries ~0.82 and
    # credit -> Refunds ~0.99.
    debit = create_transaction(account: @account, name: "WOOLWORTHS")
    credit = create_transaction(account: @account, name: "WOOLWORTHS", amount: -100)

    assert_equal @groceries.id, categorizer.classify(debit.transaction)&.first
    assert_equal refunds.id, categorizer.classify(credit.transaction)&.first
  end

  test "prior is each category's share of the training transactions" do
    15.times { create_transaction(account: @account, name: "Starbucks Coffee", category: @coffee) }
    5.times { create_transaction(account: @account, name: "Safeway Groceries", category: @groceries) }
    categorizer = Family::BayesCategorizer.new(@family)

    assert_in_delta Math.log(0.75), categorizer.send(:log_prior, @coffee.id), 1e-9
    assert_in_delta Math.log(0.25), categorizer.send(:log_prior, @groceries.id), 1e-9
  end

  test "direction and size together decide when neither does alone" do
    # Each category has small and large amounts both ways round, so money
    # in/out alone or the amount alone would be split evenly; the amount
    # Gaussians are per direction (small out vs large out), which tells them
    # apart.
    5.times { create_transaction(account: @account, name: "Acme", amount: 20, category: @groceries) }
    5.times { create_transaction(account: @account, name: "Acme", amount: -4000, category: @groceries) }
    5.times { create_transaction(account: @account, name: "Acme", amount: 4000, category: @coffee) }
    5.times { create_transaction(account: @account, name: "Acme", amount: -20, category: @coffee) }
    categorizer = Family::BayesCategorizer.new(@family)

    small_debit = create_transaction(account: @account, name: "ACME", amount: 20)
    small_credit = create_transaction(account: @account, name: "ACME", amount: -20)

    # ≈ 0.999 each way.
    assert_equal @groceries.id, categorizer.classify(small_debit.transaction)&.first
    assert_equal @coffee.id, categorizer.classify(small_credit.transaction)&.first
  end

  test "tokens: words of any script, no numbers, single letters, merchant id, account" do
    txn = create_transaction(account: @account, name: "S/O Müller 4471 Rent", amount: -2000, merchant: @starbucks).transaction

    # "s/o" splits on the symbol and keeps both letters; "4471" is dropped;
    # the merchant is one id token (its name "Starbucks" is not read);
    # direction and amount are scored separately, not as tokens.
    assert_equal [ "s", "o", "müller", "rent", "merchant:#{@starbucks.id}",
                   "account:#{@account.id}" ],
                 Family::BayesCategorizer.new(@family).send(:tokens_for, txn)
  end

  test "the merchant decides by id, and its name is not read as words" do
    10.times { create_transaction(account: @account, name: "Card Payment", merchant: @starbucks, category: @coffee) }
    10.times { create_transaction(account: @account, name: "Card Payment", merchant: @safeway, category: @groceries) }
    categorizer = Family::BayesCategorizer.new(@family)

    generic = create_transaction(account: @account, name: "CARD PAYMENT", merchant: @starbucks)
    unknown_words = create_transaction(account: @account, name: "Zzyzx", merchant: @safeway)
    name_only = create_transaction(account: @account, name: "Starbucks")

    # "card payment" is in both; only the merchant tells them apart (~0.99).
    assert_equal @coffee.id, categorizer.classify(generic.transaction)&.first
    # The merchant counts as a known word, so it classifies on its own.
    assert_equal @groceries.id, categorizer.classify(unknown_words.transaction)&.first
    # Merchant names are not tokens, so the word "starbucks" is unknown.
    assert_nil categorizer.classify(name_only.transaction)
  end

  test "complement scoring with more than two categories" do
    alpha = @family.categories.create!(name: "Alpha")
    beta = @family.categories.create!(name: "Beta")
    gamma = @family.categories.create!(name: "Gamma")
    10.times { create_transaction(account: @account, name: "Alpha", category: alpha) }
    10.times { create_transaction(account: @account, name: "Beta", category: beta) }
    30.times { create_transaction(account: @account, name: "Gamma", category: gamma) }

    txn = create_transaction(account: @account, name: "Alpha")
    category_id, confidence = Family::BayesCategorizer.new(@family).classify(txn.transaction)

    # Each txn: 1 word + the account. Words field: totals 10 / 10 / 30,
    # |V_words| = 3; account and direction have one value each, so they
    # score ln(1) = 0, and every amount is the same, so the amount densities
    # are equal and cancel. Priors 0.2 / 0.2 / 0.6. Each category is scored
    # against the pooled others:
    #   alpha: ln 0.2 - ln(0.1/40.3)
    #   beta:  ln 0.2 - ln(10.1/40.3)
    #   gamma: ln 0.6 - ln(10.1/20.3)
    # softmax(alpha) ≈ 0.97574 (multinomial NB would give ≈ 0.98039).
    assert_equal alpha.id, category_id
    assert_in_delta 0.97574, confidence, 0.00001
  end

  test "the amount counts by distance: unseen amounts go to the nearer category" do
    rent = @family.categories.create!(name: "Rent")
    10.times { |i| create_transaction(account: @account, name: "Payment", amount: 1900 + i * 20, category: rent) }
    10.times { |i| create_transaction(account: @account, name: "Payment", amount: 40 + i * 2, category: @groceries) }
    categorizer = Family::BayesCategorizer.new(@family)

    # Same words; rent ~$2,000, groceries ~$50. Neither $700 nor $150 was
    # ever seen, but on a log scale $700 is nearer $2,000 and $150 nearer $50
    # (bucket tokens gave both 0.5). $700 is past MAX_AMOUNT_Z from groceries.
    near_rent = create_transaction(account: @account, name: "PAYMENT", amount: 700)
    near_groceries = create_transaction(account: @account, name: "PAYMENT", amount: 150)

    category_id, confidence = categorizer.classify(near_rent.transaction)
    assert_equal rent.id, category_id
    assert_in_delta 0.97240, confidence, 0.00001
    assert_nil tuned(threshold: 0.98).classify(near_rent.transaction)
    category_id, confidence = categorizer.classify(near_groceries.transaction)
    assert_equal @groceries.id, category_id
    assert_in_delta 0.96802, confidence, 0.00001
  end

  test "an outlier amount doesn't outvote the merchant" do
    10.times { |i| create_transaction(account: @account, name: "Card payment", amount: 4 + i * 0.2, category: @coffee, merchant: @starbucks) }
    10.times { |i| create_transaction(account: @account, name: "Card payment", amount: 50 + i * 4, category: @groceries, merchant: @safeway) }

    # $500 is far from both categories, but much further from coffee's ~$5
    # than from groceries' ~$70. Uncapped, that distance alone gave Groceries
    # at 0.9999999999.
    outlier = create_transaction(account: @account, name: "Card payment", amount: 500, merchant: @starbucks)

    category_id, confidence = Family::BayesCategorizer.new(@family).classify(outlier.transaction)
    assert_equal @coffee.id, category_id
    assert_in_delta 0.99040, confidence, 0.00001
  end

  test "amounts are compared within their own currency" do
    lunch = @family.categories.create!(name: "Lunch")
    rent = @family.categories.create!(name: "Rent")
    # The same numbers: ¥900-1,080 lunches and $900-1,080 rent.
    10.times { |i| create_transaction(account: @account, name: "Card payment", amount: 900 + i * 20, currency: "JPY", category: lunch) }
    10.times { |i| create_transaction(account: @account, name: "Card payment", amount: 900 + i * 20, currency: "USD", category: rent) }
    categorizer = Family::BayesCategorizer.new(@family)

    # On one shared scale both would score 0.5.
    category_id, confidence = categorizer.classify(create_transaction(account: @account, name: "Card payment", amount: 1000, currency: "USD").transaction)
    assert_equal rent.id, category_id
    assert_in_delta 0.92567, confidence, 0.00001
    category_id, confidence = categorizer.classify(create_transaction(account: @account, name: "Card payment", amount: 1000, currency: "JPY").transaction)
    assert_equal lunch.id, category_id
    assert_in_delta 0.92567, confidence, 0.00001
  end

  test "settings: tokenizer options" do
    txn = create_transaction(account: @account, name: "McDonald's 2K4L19 Café a 1234", notes: "Lunch lunch").transaction
    tokens = ->(**changes) { tuned(merchant_field: false, account_field: false, **changes).send(:tokens_for, txn) }

    assert_equal %w[mcdonald s 2k4l19 café a lunch lunch], tokens.call
    assert_equal %w[mcdonald's 2k4l19 café a lunch lunch], tokens.call(word_split: "symbols")
    assert_equal %w[mcdonald s café a lunch lunch], tokens.call(drop_codes: true)
    assert_equal %w[mcdonald 2k4l19 café lunch lunch], tokens.call(keep_single_chars: false)
    assert_equal %w[mcdonald s 2k4l19 café a], tokens.call(include_notes: false)
    assert_equal %w[mcdonald s 2k4l19 caf a lunch lunch], tokens.call(word_split: "ascii")
    assert_equal %w[mcdonald s 2k4l19 café a 1234 lunch lunch], tokens.call(drop_numbers: false)
    assert_equal %w[mcdonald s 2k4l19 café a lunch], tokens.call(binary: true)
    assert_equal [ "mcdonald", "s", "2k4l19", "café", "a", "mcdonald s", "s 2k4l19", "2k4l19 café", "café a" ],
                 tokens.call(include_notes: false, bigrams: true)
  end

  test "settings: merchant name words and the merchant id" do
    txn = create_transaction(account: @account, name: "Card payment", merchant: @starbucks).transaction

    assert_equal [ "card", "payment", "starbucks" ], tuned(merchant_name_words: true, merchant_field: false, account_field: false).send(:tokens_for, txn)
    assert_equal [ "card", "payment", "account:#{@account.id}" ], tuned(merchant_field: false).send(:tokens_for, txn)
  end

  test "training stops at the as-of date" do
    train_two_categories

    assert tuned.enough_training_data?
    assert_not Family::BayesCategorizer.new(@family, as_of: Date.yesterday).enough_training_data?
  end

  test "settings: training takes the newest by creation, whatever the date, as the original does" do
    train_two_categories
    future = create_transaction(account: @account, name: "Safeway Groceries", category: @groceries, date: 1.month.from_now.to_date).transaction
    backdated = create_transaction(account: @account, name: "Starbucks Coffee", category: @coffee, date: 1.year.ago.to_date).transaction

    assert_equal [ backdated, future ], tuned.send(:training_transactions).first(2)
  end

  test "settings: excluded categories and their subcategories are left out of training" do
    train_two_categories
    food = @family.categories.create!(name: "Food")
    @coffee.update!(parent: food)
    rent = @family.categories.create!(name: "Rent")
    10.times { create_transaction(account: @account, name: "Landlord", category: rent) }

    assert_equal [ @coffee.id, @groceries.id, rent.id ].sort, tuned.send(:class_models).keys.sort
    assert_equal [ @groceries.id, rent.id ].sort, tuned(excluded_category_ids: [ food.id ]).send(:class_models).keys.sort
  end

  test "settings: transfers can be left out of training" do
    train_two_categories
    3.times { create_transaction(account: @account, name: "To savings", category: @groceries, kind: "funds_movement") }

    assert_equal 23, tuned.send(:training_transactions).size
    assert_equal 20, tuned(exclude_transfers: true).send(:training_transactions).size
  end

  test "settings: Bayes' own labels count once locked or past their grace period" do
    train_two_categories
    guess = create_transaction(account: @account, name: "Starbucks Coffee").transaction
    tuned.classify_and_apply([ guess.id ])

    travel 91.days do
      assert_equal 21, tuned.send(:training_transactions).size
      assert_equal 20, tuned(self_label_grace_days: 100).send(:training_transactions).size
      assert_equal 21, tuned(skip_self_labels: false).send(:training_transactions).size
    end
  end

  test "settings: lock_results locks Bayes' labels without counting them as confirmed" do
    train_two_categories
    guess = create_transaction(account: @account, name: "Starbucks Coffee").transaction

    tuned(lock_results: true).classify_and_apply([ guess.id ])

    assert guess.reload.locked?(:category_id)
    assert guess.data_enrichments.find_by(attribute_name: "category_id").metadata["locked_by_bayes"]
    assert_equal 20, tuned.send(:training_transactions).size
  end

  test "the account never decides alone" do
    train_two_categories
    other = @family.accounts.create!(name: "Other", balance: 0, currency: "USD", accountable: Depository.new)
    5.times { create_transaction(account: other, name: "Starbucks Coffee", category: @coffee) }
    novel = create_transaction(account: other, name: "Zzyzx").transaction

    # Only the account is known: that isn't enough to classify.
    assert_nil tuned(account_field: true, prior: true).classify(novel)
  end

  test "probabilities score every trained category, or none when it doesn't answer" do
    train_two_categories
    known = create_transaction(account: @account, name: "Starbucks Coffee").transaction
    novel = create_transaction(account: @account, name: "Zzyzx").transaction

    probabilities = tuned.probabilities(known)
    assert_equal [ @coffee.id, @groceries.id ].sort, probabilities.keys.sort
    assert_in_delta 1.0, probabilities.values.sum
    assert_equal [ @coffee.id, probabilities[@coffee.id] ], tuned(threshold: 0).classify(known)
    assert_empty tuned.probabilities(novel)
    assert_equal [ @coffee.id, @groceries.id ].sort, tuned.category_ids.sort
  end

  test "classify_and_apply returns categorized_ids and modified_count separately" do
    train_two_categories
    categorizer = Family::BayesCategorizer.new(@family)

    # A transaction whose category is already the predicted one is out of the
    # nil-category scope entirely — filtered before enrichment.
    txn = create_transaction(account: @account, name: "Starbucks Coffee")

    result = categorizer.classify_and_apply([ txn.transaction.id ])
    assert_kind_of Family::BayesCategorizer::Result, result
    assert_equal [ txn.transaction.id ], result.categorized_ids
    assert_equal 1, result.modified_count
  end
end

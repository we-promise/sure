require "test_helper"

class Family::BayesSettingsTest < ActiveSupport::TestCase
  test "defaults when nothing is stored" do
    settings = Family::BayesSettings.new

    assert_equal 0.7, settings.threshold
    assert_not settings.complement
    assert_equal [], settings.excluded_category_ids
    assert settings.default?
    assert_equal({}, settings.to_stored)
  end

  test "coerces form values, clamps numbers and drops unknown keys" do
    settings = Family::BayesSettings.new(
      "threshold" => "2", "smoothing" => "not a number", "skip_self_labels" => "0", "bigrams" => "1",
      "max_training_transactions" => "7", "word_split" => "klingon", "bogus" => "1",
      "excluded_category_ids" => [ "b", "a", "a", "" ]
    )

    assert_equal 0.99, settings.threshold
    assert_equal 1.0, settings.smoothing
    assert_equal false, settings.skip_self_labels
    assert_equal true, settings.bigrams
    assert_equal 100, settings.max_training_transactions
    assert_equal "ascii", settings.word_split
    assert_equal %w[a b], settings.excluded_category_ids
    assert_not settings.values.key?(:bogus)
  end

  test "the matcher's numbers stay within what the page offers" do
    settings = Family::BayesSettings.new("similar_threshold" => "1.5", "similar_min_neighbours" => "9", "similar_common_share" => "0")

    assert_equal 0.99, settings.similar_threshold
    assert_equal 3, settings.similar_min_neighbours
    assert_equal 0.01, settings.similar_common_share
    assert_equal 0.5, Family::BayesSettings.new("similar_threshold" => "0.1").similar_threshold
  end

  test "stores only differences from the defaults" do
    settings = Family::BayesSettings.new(threshold: 0.7, bigrams: true, smoothing: 0.1)

    assert_equal({ "bigrams" => true, "smoothing" => 0.1 }, settings.to_stored)
    assert_equal settings.values, Family::BayesSettings.new(settings.to_stored).values
  end

  test "digest is stable and follows the values" do
    assert_equal Family::BayesSettings.new.digest, Family::BayesSettings.new(threshold: "0.7").digest
    assert_not_equal Family::BayesSettings.new.digest, Family::BayesSettings.new(threshold: 0.5).digest
  end

  test "merge keeps earlier changes" do
    settings = Family::BayesSettings.new(bigrams: true).merge(threshold: "0.6")

    assert settings.bigrams
    assert_equal 0.6, settings.threshold
  end

  test "family update merges and resets blank numbers" do
    family = Family.create!(name: "Settings family")
    category = family.categories.create!(name: "Mine")

    family.update_bayes_settings!(excluded_category_ids: [ category.id ], threshold: "0.6")
    family.update_bayes_settings!(bigrams: "1")

    settings = family.reload.bayes_settings_object
    assert_equal [ category.id.to_s ], settings.excluded_category_ids
    assert_equal 0.6, settings.threshold
    assert settings.bigrams

    family.update_bayes_settings!(threshold: "")
    assert_equal 0.7, family.reload.bayes_settings_object.threshold
  end
end

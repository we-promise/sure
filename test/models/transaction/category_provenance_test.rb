require "test_helper"

class Transaction::CategoryProvenanceTest < ActiveSupport::TestCase
  setup do
    @transaction = transactions(:one)
    @food = categories(:food_and_drink)
    @income = categories(:income)
  end

  test "current when an ai enrichment matches the current category" do
    @transaction.enrich_attribute(:category_id, @income.id, source: "ai")

    provenance = @transaction.reload.category_provenance

    assert provenance.current?
    assert_not provenance.history?
    assert_equal "ai", provenance.source
    assert_equal @income.id, provenance.category_id
    assert_not_nil provenance.recorded_at
  end

  test "current when a bayes enrichment matches the current category" do
    @transaction.enrich_attribute(:category_id, @income.id, source: "bayes")

    provenance = @transaction.reload.category_provenance

    assert provenance.current?
    assert_equal "bayes", provenance.source
  end

  test "history when the category was changed after auto-categorization" do
    @transaction.enrich_attribute(:category_id, @income.id, source: "ai")
    @transaction.update!(category: @food)

    provenance = @transaction.reload.category_provenance

    assert provenance.history?
    assert_equal "ai", provenance.source
    assert_equal @income.id, provenance.category_id
  end

  test "history when the category was cleared after auto-categorization" do
    @transaction.enrich_attribute(:category_id, @income.id, source: "ai")
    @transaction.update!(category: nil)

    provenance = @transaction.reload.category_provenance

    assert provenance.history?
    assert_equal @income.id, provenance.category_id
  end

  test "latest enrichment wins when none matches the current category" do
    @transaction.enrich_attribute(:category_id, @income.id, source: "ai")

    travel 1.minute do
      @transaction.enrich_attribute(:category_id, @food.id, source: "bayes")
    end

    @transaction.update!(category: categories(:subcategory))

    provenance = @transaction.reload.category_provenance

    assert provenance.history?
    assert_equal "bayes", provenance.source
    assert_equal @food.id, provenance.category_id
  end

  test "returns nil when there are no enrichments" do
    assert_nil @transaction.category_provenance
  end

  test "returns nil when only a rule-sourced enrichment exists" do
    @transaction.enrich_attribute(:category_id, @income.id, source: "rule")

    assert_nil @transaction.reload.category_provenance
  end
end

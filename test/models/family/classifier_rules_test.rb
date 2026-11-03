require "test_helper"

class Family::ClassifierRulesTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = Family.create!(name: "Classifier rules family")
    @account = @family.accounts.create!(name: "Rules test", balance: 100, currency: "USD", accountable: Depository.new)
    @coffee = @family.categories.create!(name: "Coffee")
    @groceries = @family.categories.create!(name: "Groceries")
    @tag = @family.tags.create!(name: "Review")
  end

  test "a new family gets the matcher and Bayes at the top of its rules, on" do
    rules = @family.rules.ordered.includes(:actions)

    assert_equal [ [ "Merchant matcher", 1, true, "fill_similar_merchants" ], [ "Category classifier", 2, true, "bayes_categorize" ] ],
                 rules.map { |rule| [ rule.name, rule.position, rule.active?, rule.actions.sole.action_type ] }
    assert rules.all? { |rule| rule.conditions.none? }
  end

  test "an added rule goes in at the top, the others moving down" do
    mine = name_rule("Mine", "Starbucks", tags: [ @tag ])
    @family.classifier_rules("bayes_categorize").destroy_all
    @family.classifier_rules("fill_similar_merchants").destroy_all

    @family.add_classifier_rule!("bayes_categorize")
    @family.add_classifier_rule!("fill_similar_merchants")
    @family.classifier_rules("bayes_categorize").destroy_all
    @family.add_classifier_rule!("bayes_categorize")

    # A deleted rule leaves a gap in the numbers, as any does; the order holds.
    assert_equal [ "Category classifier", "Merchant matcher", "Mine" ], @family.rules.ordered.map(&:name)
    assert_equal [ 1, 2 ], @family.rules.ordered.first(2).map(&:position)
    assert_operator mine.reload.position, :>, 2
  end

  test "the switch is whether the rule is on" do
    @family.set_classifier_rule_active!("bayes_categorize", false)

    assert_not @family.classifier_rule_active?("bayes_categorize")
    assert @family.classifier_rule_active?("fill_similar_merchants")
    @family.classifier_rules("bayes_categorize").destroy_all
    assert_not @family.classifier_rule_active?("bayes_categorize")
  end

  test "Bayes categorizes in the rule run, and a rule below it can still change its pick" do
    train_two_categories
    picked = uncategorized("Starbucks Coffee")
    corrected = uncategorized("Starbucks Coffee beans")
    name_rule("Beans", "beans", category: @groceries)

    ApplyRulesJob.perform_now(@family)

    assert_equal @coffee, picked.reload.category
    assert_equal "bayes", picked.data_enrichments.find_by(attribute_name: "category_id").source
    assert_equal @groceries, corrected.reload.category
  end

  test "a rule moved above Bayes that stops processing keeps Bayes off its transactions" do
    train_two_categories
    held = uncategorized("Starbucks Coffee")
    exception = name_rule("Hold for review", "Starbucks", tags: [ @tag ], stop_processing: true)
    Rule.update_positions!(@family, [ exception.id ] + (@family.rules.ordered.ids - [ exception.id ]))

    ApplyRulesJob.perform_now(@family)

    assert_nil held.reload.category
    assert_includes held.tags, @tag
  end

  test "applying a rule below them runs the matcher and Bayes first" do
    train_two_categories
    transaction = uncategorized("Starbucks Coffee")
    tagging = name_rule("Tag coffee", "Starbucks", tags: [ @tag ])

    RuleJob.perform_now(tagging)

    assert_equal @coffee, transaction.reload.category
    assert_includes transaction.tags, @tag
  end

  private
    # 10 coffee + 10 groceries, so the Bayes training guard passes (as in
    # AutoCategorizeTransactionsTest).
    def train_two_categories
      10.times { create_transaction(account: @account, name: "Starbucks Coffee", category: @coffee) }
      10.times { create_transaction(account: @account, name: "Safeway Groceries", category: @groceries) }
    end

    def uncategorized(name)
      create_transaction(account: @account, name: name).transaction
    end

    def name_rule(name, match, category: nil, tags: nil, stop_processing: false)
      actions = []
      actions << Rule::Action.new(action_type: "set_transaction_category", value: category.id) if category
      actions << Rule::Action.new(action_type: "set_transaction_tags", value: tags.map(&:id)) if tags
      @family.rules.create!(name: name, resource_type: "transaction", active: true, stop_processing: stop_processing,
                            conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: match) ],
                            actions: actions)
    end
end

require "test_helper"

class Rule::LocalizationTest < ActiveSupport::TestCase
  setup do
    Current.session = Session.new(user: users(:family_admin))
    @rule = Rule.new(family: families(:dylan_family), resource_type: "transaction")
  end

  teardown { Current.reset }

  test "Russian registry labels preserve filter action operator and option values" do
    classes = Rule::Registry::TransactionResource::CONDITION_FILTER_CLASSES +
      Rule::Registry::TransactionResource::ACTION_EXECUTOR_CLASSES

    classes.each do |klass|
      owner = klass.new(@rule)
      english = I18n.with_locale(:en) { owner.as_json }
      russian = I18n.with_locale(:ru) { owner.as_json }

      assert_match(/[А-Яа-яЁё]/, russian.fetch(:label), klass.name)
      assert_equal english.values_at(:key, :type), russian.values_at(:key, :type)
      assert_equal Array(english[:operators]).map(&:last), Array(russian[:operators]).map(&:last)
      assert_equal Array(english[:options]).map(&:last), Array(russian[:options]).map(&:last)
    end
  end

  test "Russian resource plurals and condition summaries do not change stored values" do
    condition = @rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "Coffee")

    I18n.with_locale(:ru) do
      { 0 => "операций", 1 => "операция", 2 => "операции", 5 => "операций", 21 => "операция" }.each do |count, label|
        assert_equal label, @rule.resource_name(count: count)
      end
      assert_equal "Содержит", condition.operator_display
      assert_equal "Если название операции содержит Coffee", @rule.primary_condition_title
      assert_equal "правило", Rule.model_name.human
      assert_equal "like", condition.operator
      assert_equal "Coffee", condition.value
      assert_equal "transaction", @rule.resource_type
      condition.operator = "legacy_operator"
      assert_equal "legacy_operator", condition.operator_display
    end

    I18n.with_locale(:en) do
      condition.operator = "like"
      assert_equal "If transaction name contains Coffee", @rule.primary_condition_title
      assert_equal "Rule", Rule.model_name.human
      assert_equal "transaction", @rule.resource_name(count: 1)
      assert_equal "transactions", @rule.resource_name
    end
  end

  test "AI action labels localize configured unknown and missing costs without changing English" do
    family = @rule.family
    family.stubs(:self_hoster?).returns(true)
    family.stubs(:categorization_model_name).returns("example-model")
    executor = Rule::ActionExecutor::AutoCategorize.new(@rule)
    LlmUsage.stubs(:estimate_auto_categorize_cost).returns(BigDecimal("0.0123"))

    I18n.with_locale(:ru) do
      assert_equal "Назначить категории с помощью ИИ (~$0.0123 за 20 операций)", executor.label
      LlmUsage.stubs(:estimate_auto_categorize_cost).returns(nil)
      assert_equal "Назначить категории с помощью ИИ (стоимость неизвестна)", executor.label
      family.stubs(:categorization_model_name).returns(nil)
      assert_equal "Назначить категории с помощью ИИ (поставщик категоризации не настроен)", executor.label
      assert_equal "Определить продавцов с помощью ИИ ($$)", Rule::ActionExecutor::AutoDetectMerchants.new(@rule).label
    end

    I18n.with_locale(:en) do
      assert_equal "Auto-categorize transactions with AI (no categorization provider configured)", executor.label
      assert_equal "Auto-detect merchants with AI ($$)", Rule::ActionExecutor::AutoDetectMerchants.new(@rule).label
    end

    family.stubs(:self_hoster?).returns(false)
    I18n.with_locale(:ru) do
      assert_equal "Назначить категории с помощью ИИ", executor.label
      assert_equal "Определить продавцов автоматически", Rule::ActionExecutor::AutoDetectMerchants.new(@rule).label
    end
  end
end

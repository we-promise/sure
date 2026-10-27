require "test_helper"

class Rule::RegistryLocalizationTest < ActiveSupport::TestCase
  setup do
    @previous_current_session = Current.session
    Current.session = sessions(:one)
    @rule = rules(:one)
    @rule.family.stubs(:self_hoster?).returns(false)
  end

  teardown do
    Current.session = @previous_current_session
  end

  test "all registered condition labels use the current locale while keys and operators stay stable" do
    filters = @rule.condition_filters
    baseline = filters.to_h { |filter| [ filter.key, filter.operators.map(&:last) ] }
    I18n.with_locale(:"zh-CN") do
      assert_equal [ "交易名称", "交易金额", "交易类型", "交易商户", "交易分类", "交易标签", "交易明细", "交易备注", "交易账户" ], filters.map(&:label)
    end
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      I18n.with_locale(locale) do
        filters.each do |filter|
          key = "rules.condition_filters.labels.#{filter.key}"
          assert I18n.exists?(key, locale, fallback: false), "#{locale} #{key}"
          assert_equal I18n.t(key, raise: true), filter.label
          assert_equal filter.label, filter.as_json[:label]
          assert_equal baseline.fetch(filter.key), filter.operators.map(&:last)
        end
      end
    end
  end

  test "all action display names are translated without changing action keys or types" do
    classes = [
      Rule::ActionExecutor::SetTransactionCategory, Rule::ActionExecutor::SetTransactionTags,
      Rule::ActionExecutor::SetTransactionMerchant, Rule::ActionExecutor::SetTransactionName,
      Rule::ActionExecutor::SetInvestmentActivityLabel, Rule::ActionExecutor::ExcludeTransaction,
      Rule::ActionExecutor::SetAsTransferOrPayment, Rule::ActionExecutor::SendEmailNotification,
      Rule::ActionExecutor::AutoCategorize, Rule::ActionExecutor::AutoDetectMerchants,
      Rule::ActionExecutor::SplitTransaction, Rule::ActionExecutor::FillSimilarMerchants,
      Rule::ActionExecutor::BayesCategorize
    ]
    actions = classes.map { |klass| klass.new(@rule) }
    I18n.with_locale(:"zh-CN") do
      assert_equal [ "设置交易分类", "设置交易标签", "设置交易商户", "设置交易名称", "设置投资活动类型", "从预算和报表中排除", "设为转账或还款", "发送邮件通知", "使用 AI 自动分类交易", "自动识别商户", "拆分交易", "根据相似交易补全商户（无需 AI）", "使用分类器进行分类（无需 AI）" ], actions.map(&:label)
    end
    baseline = actions.to_h { |action| [ action.key, action.type ] }
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      I18n.with_locale(locale) do
        actions.each do |action|
          key = "rules.action_executors.labels.#{action.key}"
          assert I18n.exists?(key, locale, fallback: false), "#{locale} #{key}"
          assert_equal I18n.t(key, raise: true), action.label
          assert_equal action.label, action.as_json[:label]
          assert_equal baseline.fetch(action.key), action.type
        end
      end
    end
  end

  test "investment option labels use translations but stored activity values stay unchanged" do
    executor = Rule::ActionExecutor::SetInvestmentActivityLabel.new(@rule)
    I18n.with_locale(:"zh-CN") do
      assert_equal I18n.t("transactions.activity_labels.buy"), executor.options.first.first
    end
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      I18n.with_locale(locale) do
        assert_equal Transaction::ACTIVITY_LABELS, executor.options.map(&:last)
        executor.options.each do |label, value|
          assert_equal I18n.t("transactions.activity_labels.#{value.parameterize(separator: '_')}", raise: true), label
        end
      end
    end
  end

  test "user supplied category account merchant and tag option labels remain identical across locales" do
    items = @rule.condition_filters.select { |filter| %w[transaction_category transaction_account transaction_merchant transaction_tag].include?(filter.key) }
    items += [ Rule::ActionExecutor::SetTransactionCategory, Rule::ActionExecutor::SetTransactionMerchant, Rule::ActionExecutor::SetTransactionTags, Rule::ActionExecutor::SetAsTransferOrPayment ].map { |klass| klass.new(@rule) }
    before = items.map(&:options)
    LanguagesHelper::SUPPORTED_LOCALES.each { |locale| I18n.with_locale(locale) { assert_equal before, items.map(&:options) } }
  end

  test "AI display cost uses local decimals and preserves four places and the twenty transaction estimate" do
    @rule.family.stubs(:self_hoster?).returns(true)
    @rule.family.stubs(:categorization_model_name).returns("synthetic-model")
    LlmUsage.stubs(:estimate_auto_categorize_cost).returns(BigDecimal("0.0120"))
    executor = Rule::ActionExecutor::AutoCategorize.new(@rule)
    I18n.with_locale(:de) do
      assert_includes executor.label, "0,0120"
      assert_includes executor.label, "20"
      assert_includes executor.label, I18n.t("rules.action_executors.labels.auto_categorize", raise: true)
    end
    I18n.with_locale(:"zh-CN") { assert_includes executor.label, "0.0120" }
    LlmUsage.stubs(:estimate_auto_categorize_cost).returns(nil)
    I18n.with_locale(:"zh-CN") { assert_includes executor.label, "费用未知" }
    @rule.family.stubs(:categorization_model_name).returns(nil)
    I18n.with_locale(:"zh-CN") { assert_includes executor.label, "未配置分类服务" }
    I18n.with_locale(:"zh-CN") do
      assert_equal "使用 AI 自动识别商户（$$）", Rule::ActionExecutor::AutoDetectMerchants.new(@rule).label
    end
  end
end

require "test_helper"

class LocalizedRuleMessagesTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    ensure_tailwind_build
  end

  test "new rule chrome is localized and synthetic rule values are unchanged" do
    name = '<img src=x onerror="synthetic()"> User-entered name'
    get new_rule_url(resource_type: "transaction", name: name, locale: "zh-CN")
    assert_response :success
    assert_select "a[href=?]", rules_path, text: "返回规则"
    assert_select "h2", text: "新建交易规则"
    assert_select "input[name='rule[name]'][value=?]", name
    assert_select "img[src='x']", count: 0
    assert_select "[data-condition-prefix] span", text: I18n.t("rule.conditions.condition_group.and_prefix", locale: "zh-CN")
    assert_select "h3", text: "适用范围"
  end

  test "server renders localized dynamic messages for rules tags and confirmation" do
    %w[zh-CN de es].each do |locale|
      # Instantiate visible condition/action fields. Empty new rules only have
      # inert templates, whose content is not part of the rendered form DOM.
      get new_rule_url(resource_type: "transaction", locale: locale,
                       name: "Synthetic condition", action_type: "set_transaction_tags",
                       action_value: tags(:one).id)
      assert_response :success
      assert_select "[data-controller='rule--conditions']" do |conditions|
        assert conditions.all? { |node| node["data-rule--conditions-value-placeholder-value"] == I18n.t("rule.conditions.condition.value_placeholder", locale: locale) }
      end
      assert_select "[data-controller='rule--actions']" do |actions|
        assert actions.all? { |node| node["data-rule--actions-none-label-value"] == I18n.t("transactions.form.none", locale: locale) }
      end
      assert_select "[data-controller='tag-select']" do |selects|
        assert selects.all? { |node| node["data-tag-select-create-error-value"] == I18n.t("tags.create.failed", locale: locale, raise: true) }
      end
      assert_select "#confirm-dialog" do |dialogs|
        labels = JSON.parse(dialogs.first["data-confirm-dialog-labels-value"])
        assert_equal I18n.t("layouts.shared.confirm_dialog.are_you_sure", locale: locale), labels.fetch("are_you_sure")
        assert_equal I18n.t("layouts.shared.confirm_dialog.cannot_be_undone", locale: locale), labels.fetch("cannot_be_undone")
        assert_equal I18n.t("layouts.shared.confirm_dialog.confirm", locale: locale), labels.fetch("confirm")
      end
    end
  end
  test "editing a rule localizes its title and preserves the literal user name" do
    rule = rules(:one)
    get edit_rule_url(rule, locale: "zh-CN")
    assert_response :success
    assert_select "a[href=?]", rules_path, text: "返回规则"
    assert_select "h2", text: "编辑交易规则"

    name = '<img src=x onerror="synthetic()"> User rule'
    rule.update!(name: name)
    get edit_rule_url(rule, locale: "zh-CN")
    assert_response :success
    assert_select "h2", text: "编辑交易规则“#{name}”"
    assert_select "img[src='x']", count: 0
    assert_select "input[name='rule[name]'][value=?]", name
  end
end

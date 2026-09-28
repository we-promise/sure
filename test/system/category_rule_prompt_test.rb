require "application_system_test_case"

class CategoryRulePromptTest < ApplicationSystemTestCase
  include ActionView::RecordIdentifier

  setup do
    sign_in @user = users(:family_admin)
    @user.update!(rule_prompts_disabled: false, rule_prompt_dismissed_at: nil)
    @entry = @user.family.entries.transactions.order(date: :desc).first
    ruled_category_ids = Rule::Action.joins(:rule)
                                     .where(rules: { family_id: @user.family_id }, action_type: "set_transaction_category")
                                     .pluck(:value)
    # Filtered in Ruby: rule action values are free-form strings, and a non-UUID one
    # would turn a SQL NOT IN into NOT IN (NULL), which matches nothing.
    @categories = @user.family.categories.alphabetically.reject do |category|
      category.id.in?(ruled_category_ids) || category.id == @entry.entryable.category_id
    end.first(2)
    assert_equal 2, @categories.size, "fixtures need two categories without a rule"
    page.current_window.resize_to(1280, 900)
  end

  test "closing the prompt hides only that prompt and does not snooze future ones" do
    visit transactions_url
    assign_category @categories.first

    within "#cta" do
      assert_text "Updated to #{@categories.first.name}"
      assert_text "Hide for today pauses these suggestions for 24 hours."
    end

    # The X sits in the toast's top-right corner (not pushed down by the content stack).
    offsets = page.evaluate_script(<<~JS)
      (() => {
        const toast = document.querySelector("#cta > div");
        const close = toast.querySelector("button[aria-label='Close']");
        const t = toast.getBoundingClientRect(), c = close.getBoundingClientRect();
        return { top: c.top - t.top, right: t.right - c.right };
      })()
    JS
    assert_operator offsets["top"], :<=, 12
    assert_operator offsets["right"], :<=, 12

    within("#cta") { click_button "Close" }

    assert_no_text "Updated to #{@categories.first.name}"
    assert_nil @user.reload.rule_prompt_dismissed_at

    assign_category @categories.second
    assert_selector "#cta", text: "Updated to #{@categories.second.name}"
  end

  test "hide for today snoozes rule prompts" do
    visit transactions_url
    assign_category @categories.first

    within("#cta") { click_button "Hide for today" }

    assert_no_text "Updated to #{@categories.first.name}"
    assert_not_nil @user.reload.rule_prompt_dismissed_at
    assert_not @user.rule_prompts_disabled

    # While snoozed, the next eligible category change doesn't prompt either.
    assign_category @categories.second
    assert_no_text "Updated to #{@categories.second.name}"
  end

  private
    def assign_category(category)
      within "##{dom_id(@entry.entryable, 'category_menu_desktop')}" do
        find("button", match: :first).click
      end

      within "turbo-frame#category_dropdown" do
        find("input[type='search']").fill_in with: category.name
        find("##{dom_id(category, 'category_option')} button", match: :first).click
      end

      assert_selector "##{dom_id(@entry.entryable, 'category_menu_desktop')} [data-testid='category-name']", text: category.name
    end
end

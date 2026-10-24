require "test_helper"

class CategoryEmojiDisplayTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @category = @user.family.categories.create!(name: "Synthetic emoji category", color: "#6471eb", lucide_icon: "coffee", emoji: "👩🏽‍💻")
  end

  test "editing a saved emoji exposes its complete value and optional input without character truncation" do
    get edit_category_path(@category), headers: { "Turbo-Frame" => "modal" }
    assert_response :success
    assert_select "input[name='category[emoji]'][value='👩🏽‍💻']:not([maxlength])"
    assert_select "[data-color-icon-picker-target='avatar'] [data-emoji-glyph]", text: "👩🏽‍💻"
    assert_select "template[data-color-icon-picker-target='emojiFallback'] svg"
    assert_select "input[name='category[lucide_icon]'][value='coffee'][data-action*='click->color-icon-picker#handleIconChange']"
    assert_select "button[data-emoji='👨‍👩‍👧‍👦'][type='button']"
    assert_select "button[data-action='click->color-icon-picker#clearEmoji'][type='button']"
  end

  test "category list preserves parent and child emoji independently" do
    child = @user.family.categories.create!(name: "Synthetic child", color: "#6471eb", lucide_icon: "home", parent: @category, emoji: "🇨🇳")
    get categories_path
    assert_response :success
    assert_select "#category_#{@category.id} [data-emoji-glyph]", text: "👩🏽‍💻"
    assert_select "#category_#{child.id} [data-emoji-glyph]", text: "🇨🇳"
    assert_equal @category.id, child.reload.parent_id
  end

  test "transaction list and drawer display the selected category emoji" do
    entry = create_transaction(category: @category, name: "Synthetic expense")
    get transactions_path
    assert_response :success
    assert_select "[data-emoji-glyph]", text: "👩🏽‍💻", minimum: 1
    get transaction_path(entry), headers: { "Turbo-Frame" => "drawer" }
    assert_response :success
    assert_select "[data-emoji-glyph]", text: "👩🏽‍💻", minimum: 1
  end

  test "reports retain parent and child emoji alongside category hierarchy" do
    child = @user.family.categories.create!(name: "Synthetic report child", color: "#6471eb", lucide_icon: "home", parent: @category, emoji: "👨‍👩‍👧‍👦")
    create_transaction(category: child, date: Date.current, amount: 30)
    get reports_path(period_type: :custom, start_date: Date.current, end_date: Date.current)
    assert_response :success
    assert_select "tr[data-category='category-#{@category.id}'] [data-emoji-glyph]", text: "👩🏽‍💻"
    assert_select "tr[data-category='category-#{child.id}'] [data-emoji-glyph]", text: "👨‍👩‍👧‍👦"
  end

  test "dashboard category charts retain the complete emoji" do
    create_transaction(category: @category, date: Date.current, amount: 40)
    get root_path
    assert_response :success
    assert_select "#outflows-donut-section [data-emoji-glyph]", text: "👩🏽‍💻", minimum: 1
  end

  test "cleared emoji leaves the original icon on the next edit" do
    @category.update!(emoji: nil)
    get edit_category_path(@category), headers: { "Turbo-Frame" => "modal" }
    assert_response :success
    assert_select "[data-color-icon-picker-target='avatar'] svg"
    assert_select "[data-color-icon-picker-target='avatar'] [data-emoji-glyph]", count: 0
    assert_select "input[name='category[lucide_icon]'][value='coffee'][checked]"
  end
end

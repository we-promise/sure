require "application_system_test_case"

class Transactions::CategoryFilterTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)

    # Ensure we have a parent category with subcategory
    @parent = categories(:food_and_drink)
    @subcategory = categories(:subcategory) # Restaurants
  end

  test "category filter shows hierarchical indentation for subcategories" do
    visit transactions_url

    within "[data-controller*='cascading-category-filter']" do
      # Parent category should exist
      assert_selector "[data-filter-name='#{@parent.name}']"

      # Subcategory should have ml-4 class for indentation
      subcategory_item = find("[data-filter-name='#{@subcategory.name}']")
      assert subcategory_item[:class].include?("ml-4"), "Subcategory should have ml-4 indentation class"
    end
  end

  test "selecting parent category auto-selects subcategories" do
    visit transactions_url

    within "[data-controller*='cascading-category-filter']" do
      parent_checkbox = find("input[type='checkbox'][data-category-id='#{@parent.id}']", visible: :all)
      subcategory_checkbox = find("input[type='checkbox'][data-category-id='#{@subcategory.id}']", visible: :all)

      # Initially unchecked
      assert_not parent_checkbox.checked?
      assert_not subcategory_checkbox.checked?

      # Check parent
      parent_checkbox.check

      # Subcategory should now be checked
      assert subcategory_checkbox.checked?, "Subcategory should be auto-checked when parent is checked"
    end
  end

  test "unchecking parent category unchecks subcategories" do
    visit transactions_url

    within "[data-controller*='cascading-category-filter']" do
      parent_checkbox = find("input[type='checkbox'][data-category-id='#{@parent.id}']", visible: :all)
      subcategory_checkbox = find("input[type='checkbox'][data-category-id='#{@subcategory.id}']", visible: :all)

      # Check parent (which auto-checks subcategory)
      parent_checkbox.check
      assert subcategory_checkbox.checked?

      # Uncheck parent
      parent_checkbox.uncheck

      # Subcategory should now be unchecked
      assert_not subcategory_checkbox.checked?, "Subcategory should be unchecked when parent is unchecked"
    end
  end

  test "can uncheck subcategory independently of parent" do
    visit transactions_url

    within "[data-controller*='cascading-category-filter']" do
      parent_checkbox = find("input[type='checkbox'][data-category-id='#{@parent.id}']", visible: :all)
      subcategory_checkbox = find("input[type='checkbox'][data-category-id='#{@subcategory.id}']", visible: :all)

      # Check parent (which auto-checks subcategory)
      parent_checkbox.check
      assert subcategory_checkbox.checked?

      # Uncheck subcategory individually
      subcategory_checkbox.uncheck

      # Parent should still be checked, subcategory unchecked
      assert parent_checkbox.checked?, "Parent should remain checked"
      assert_not subcategory_checkbox.checked?, "Subcategory should be unchecked independently"
    end
  end
end

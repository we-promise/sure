require "test_helper"

class LayoutAccessibilityTest < ActionDispatch::IntegrationTest
  setup do
    user = users(:family_admin)
    user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in user
  end

  test "application layout renders skip-link pointing at #main and a <main> with id=\"main\"" do
    get root_path
    assert_response :ok

    skip_text = I18n.t("layouts.application.skip_to_main")

    assert_select "a[href=\"#main\"]", text: skip_text
    assert_select "main#main"
  end

  test "settings layout renders skip-link pointing at #main and a <main> with id=\"main\"" do
    get settings_profile_path
    assert_response :ok

    skip_text = I18n.t("layouts.application.skip_to_main")

    assert_select "a[href=\"#main\"]", text: skip_text
    assert_select "main#main"
  end

  test "admin application layout renders tax imports and exports navigation links" do
    get root_path
    assert_response :ok

    assert_select "a[href='#{tax_workbook_imports_path}']"
    assert_select "a[href='#{imports_path}']"
    assert_select "a[href='#{family_exports_path}']"

    hrefs = css_select("div.hidden.lg\\:block.border-r nav ul li a").map { |link| link["href"] }
    budgets_index = hrefs.index(budgets_path)
    tax_index = hrefs.index(tax_workbook_imports_path)
    imports_index = hrefs.index(imports_path)
    exports_index = hrefs.index(family_exports_path)
    goals_index = hrefs.index(goals_path)

    assert_not_nil budgets_index
    assert_not_nil tax_index
    assert_not_nil imports_index
    assert_not_nil exports_index
    assert_not_nil goals_index
    assert_operator budgets_index, :<, tax_index
    assert_operator tax_index, :<, imports_index
    assert_operator imports_index, :<, exports_index
    assert_operator exports_index, :<, goals_index
  end

  test "non admin application layout hides tax imports and exports navigation links" do
    sign_in users(:family_member)

    get root_path
    assert_response :ok

    assert_select "a[href='#{tax_workbook_imports_path}']", count: 0
    assert_select "a[href='#{imports_path}']", count: 0
    assert_select "a[href='#{family_exports_path}']", count: 0
  end
end

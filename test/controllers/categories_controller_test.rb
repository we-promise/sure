require "test_helper"

class CategoriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @transaction = transactions :one
    ensure_tailwind_build
  end

  test "index" do
    get categories_url
    assert_response :success
    assert_select "#category_#{categories(:food_and_drink).id} > [data-testid='category-content']", count: 1
    assert_select "#category_#{categories(:food_and_drink).id} > [data-testid='category-actions']", count: 1
    assert_select "#category_#{categories(:food_and_drink).id} [data-testid='category-name']", text: categories(:food_and_drink).name
  end

  test "index avoids per-category subcategory and transaction existence queries" do
    4.times do |idx|
      parent = @family.categories.create!(
        name: "Performance Parent #{idx}",
        color: "#000000",
        lucide_icon: "folder"
      )
      child = @family.categories.create!(
        name: "Performance Child #{idx}",
        color: "#111111",
        lucide_icon: "folder",
        parent: parent
      )
      transaction = Transaction.create!(category: child)
      Entry.create!(
        account: accounts(:depository),
        entryable: transaction,
        name: "Performance transaction #{idx}",
        date: Date.current,
        amount: 10,
        currency: "USD"
      )
    end

    queries = capture_sql_queries { get categories_url }

    assert_response :success
    assert_select "[data-testid='category-name']", text: "Performance Parent 0"
    assert_select "[data-testid='category-name']", text: "Performance Child 0"

    assert_empty queries.grep(/FROM "categories" WHERE "categories"\."parent_id" =/)
    assert_empty queries.grep(/FROM "transactions" WHERE "transactions"\."category_id" =/)
  end

  test "new" do
    get new_category_url
    assert_response :success
  end

  test "create" do
    color = Category::COLORS.sample

    assert_difference "Category.count", +1 do
      post categories_url, params: {
        category: {
          name: "New Category",
          color: color } }
    end

    new_category = Category.order(:created_at).last

    assert_redirected_to categories_url
    assert_equal "New Category", new_category.name
    assert_equal color, new_category.color
  end

  test "create fails if name is not unique" do
    assert_no_difference "Category.count" do
      post categories_url, params: {
        category: {
          name: categories(:food_and_drink).name,
          color: Category::COLORS.sample } }
    end

    assert_response :unprocessable_entity
  end

  test "create and assign to transaction" do
    color = Category::COLORS.sample

    assert_difference "Category.count", +1 do
      post categories_url, params: {
        transaction_id: @transaction.id,
        category: {
          name: "New Category",
          color: color } }
    end

    new_category = Category.order(:created_at).last

    assert_redirected_to categories_url
    assert_equal "New Category", new_category.name
    assert_equal color, new_category.color
    assert_equal @transaction.reload.category, new_category
  end

  test "edit" do
    get edit_category_url(categories(:food_and_drink))
    assert_response :success
  end

  test "update" do
    new_color = Category::COLORS.without(categories(:income).color).sample

    assert_changes -> { categories(:income).name }, to: "New Name" do
      assert_changes -> { categories(:income).reload.color }, to: new_color do
        patch category_url(categories(:income)), params: {
          category: {
            name: "New Name",
            color: new_color } }
      end
    end

    assert_redirected_to categories_url
  end

  test "bootstrap" do
    # 22 default categories minus 2 that already exist in fixtures (Income, Food & Drink)
    assert_difference "Category.count", 20 do
      post bootstrap_categories_url
    end

    assert_redirected_to categories_url
  end

  test "merge renders in the settings layout" do
    get merge_categories_path

    assert_response :success
    assert_select "#mobile-settings-nav"
  end

  test "merge renders without the settings layout for modal frame requests" do
    get merge_categories_path, headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_no_match(/<html/i, response.body)
    assert_no_match(/<turbo-frame id="modal"><\/turbo-frame>/, response.body)
    assert_select "dialog"
  end

  test "merge selected categories into an existing category" do
    target = @family.categories.create!(
      name: "Dining",
      color: "#111111",
      lucide_icon: "utensils"
    )
    source = @family.categories.create!(
      name: "Coffee Shops",
      color: "#000000",
      lucide_icon: "coffee"
    )
    transaction = Transaction.create!(category: source)
    Entry.create!(
      account: accounts(:depository),
      entryable: transaction,
      name: "Coffee transaction",
      date: Date.current,
      amount: 10,
      currency: "USD"
    )

    assert_difference "Category.count", -1 do
      post perform_merge_categories_path, params: {
        target_id: target.id,
        source_ids: [ source.id ]
      }
    end

    assert_redirected_to categories_path
    assert_equal target, transaction.reload.category
    assert_not Category.exists?(source.id)
  end

  test "merge redirects when a source category cannot be destroyed" do
    target = @family.categories.create!(
      name: "Destroy Failure Target",
      color: "#000000",
      lucide_icon: "shapes"
    )
    source = @family.categories.create!(
      name: "Destroy Failure Source",
      color: "#111111",
      lucide_icon: "shapes"
    )

    Category::Merger.any_instance
                    .stubs(:merge!)
                    .raises(ActiveRecord::RecordNotDestroyed.new("cannot destroy category", source))

    post perform_merge_categories_path, params: {
      target_id: target.id,
      source_ids: [ source.id ]
    }

    assert_redirected_to merge_categories_path
    assert Category.exists?(source.id)
  end

  test "merge rejects selecting the target as a source" do
    target = @family.categories.create!(
      name: "Self Target",
      color: "#000000",
      lucide_icon: "shapes"
    )
    source = @family.categories.create!(
      name: "Self Source",
      color: "#111111",
      lucide_icon: "shapes"
    )

    post perform_merge_categories_path, params: {
      target_id: target.id,
      source_ids: [ target.id, source.id ]
    }

    assert_redirected_to merge_categories_path
    assert Category.exists?(target.id)
    assert Category.exists?(source.id)
  end

  test "merge rejects parent category into any descendant" do
    parent = @family.categories.create!(
      name: "Parent Category",
      color: "#000000",
      lucide_icon: "folder"
    )
    child = @family.categories.create!(
      name: "Child Category",
      color: "#111111",
      lucide_icon: "folder",
      parent: parent
    )
    grandchild = @family.categories.create!(
      name: "Grandchild Category",
      color: "#222222",
      lucide_icon: "folder"
    )
    # Category validation normally prevents this depth; the merger still guards
    # against stale or imported data with deeper hierarchies.
    grandchild.update_column(:parent_id, child.id)

    post perform_merge_categories_path, params: {
      target_id: grandchild.id,
      source_ids: [ parent.id ]
    }

    assert_redirected_to merge_categories_path
    assert Category.exists?(parent.id)
  end

  test "merge reparents source children to target category" do
    target = @family.categories.create!(
      name: "Target Category",
      color: "#000000",
      lucide_icon: "folder"
    )
    source = @family.categories.create!(
      name: "Source Category",
      color: "#111111",
      lucide_icon: "folder"
    )
    child = @family.categories.create!(
      name: "Source Child Category",
      color: "#222222",
      lucide_icon: "folder",
      parent: source
    )

    post perform_merge_categories_path, params: {
      target_id: target.id,
      source_ids: [ source.id ]
    }

    assert_redirected_to categories_path
    assert_equal target.id, child.reload.parent_id
    assert_not Category.exists?(source.id)
  end

  test "merge rejects moving source children under a subcategory target" do
    parent = @family.categories.create!(
      name: "Target Parent Category",
      color: "#000000",
      lucide_icon: "folder"
    )
    target = @family.categories.create!(
      name: "Target Subcategory",
      color: "#111111",
      lucide_icon: "folder",
      parent: parent
    )
    source = @family.categories.create!(
      name: "Source With Child",
      color: "#222222",
      lucide_icon: "folder"
    )
    child = @family.categories.create!(
      name: "Source Child",
      color: "#333333",
      lucide_icon: "folder",
      parent: source
    )

    post perform_merge_categories_path, params: {
      target_id: target.id,
      source_ids: [ source.id ]
    }

    assert_redirected_to merge_categories_path
    assert Category.exists?(source.id)
    assert_equal source.id, child.reload.parent_id
  end

  test "merge ignores categories outside current family" do
    other = families(:empty).categories.create!(
      name: "Other Family Category",
      color: "#000000",
      lucide_icon: "shapes"
    )

    post perform_merge_categories_path, params: {
      target_id: categories(:income).id,
      source_ids: [ other.id ]
    }

    assert_redirected_to merge_categories_path
    assert Category.exists?(other.id)
  end

  private
    def capture_sql_queries
      queries = []
      callback = lambda do |_name, _started, _finished, _unique_id, payload|
        next if payload[:cached]
        next if %w[SCHEMA TRANSACTION].include?(payload[:name])

        queries << payload[:sql].squish
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        yield
      end

      queries
    end
end

require "test_helper"

class Category::DeletionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @category = categories(:food_and_drink)
    tailwind_build = Rails.root.join("app/assets/builds/tailwind.css")
    FileUtils.mkdir_p(tailwind_build.dirname)
    File.write(tailwind_build, "/* test */") unless tailwind_build.exist?
  end

  test "new" do
    get new_category_deletion_url(@category)
    assert_response :success
    assert_select "turbo-frame#modal"
    assert_match(/<div class="grow py-4 space-y-4 flex flex-col ">/, response.body)
  end

  test "create with replacement" do
    replacement_category = categories(:income)

    assert_not_empty @category.transactions

    assert_difference "Category.count", -1 do
      assert_difference "replacement_category.transactions.count", @category.transactions.count do
        post category_deletions_url(@category),
          params: { replacement_category_id: replacement_category.id }
      end
    end

    assert_redirected_to transactions_url
  end

  test "create without replacement" do
    assert_not_empty @category.transactions

    assert_difference "Category.count", -1 do
      assert_difference "Transaction.where(category: nil).count", @category.transactions.count do
        post category_deletions_url(@category)
      end
    end

    assert_redirected_to transactions_url
  end
end

require "test_helper"

class Assistant::Function::GetTagsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::GetTags.new(@user)
  end

  test "to_definition returns correct name and description" do
    definition = @fn.to_definition
    assert_equal "get_tags", definition[:name]
    assert_not_empty definition[:description]
    assert_equal "object", definition[:params_schema][:type]
  end

  test "returns paginated tags sorted alphabetically" do
    result = @fn.call({ "page" => 1 })

    assert_kind_of Array, result[:tags]
    assert_equal 1, result[:page]
    assert result[:total_results] >= result[:tags].size
    assert result[:total_pages] >= 1
    assert_equal Assistant::Function::GetTags.default_page_size, result[:page_size]

    names = result[:tags].map { |t| t[:name] }
    assert_equal names.sort, names
  end

  test "each tag includes id, name, and color" do
    result = @fn.call({ "page" => 1 })
    result[:tags].each do |t|
      assert t[:id].present?
      assert t[:name].present?
      assert t[:color].present?
    end
  end

  test "scopes to the user's family" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    other_family.tags.create!(name: "Foreign Tag")

    result = @fn.call({ "page" => 1 })
    tag_names = result[:tags].map { |t| t[:name] }
    assert_not_includes tag_names, "Foreign Tag"
  end

  test "defaults to page 1 when page param is omitted" do
    result_with_page = @fn.call({ "page" => 1 })
    result_without_page = @fn.call

    assert_equal result_with_page[:page], result_without_page[:page]
    assert_equal result_with_page[:total_results], result_without_page[:total_results]
  end

  test "paginates correctly when there are multiple pages" do
    50.times { |i| @family.tags.create!(name: "PaginationTag#{format('%02d', i)}") }

    page1 = @fn.call({ "page" => 1 })
    page2 = @fn.call({ "page" => 2 })

    assert page1[:total_pages] > 1
    assert_equal 1, page1[:page]
    assert_equal 2, page2[:page]
    assert_not_equal page1[:tags].map { |t| t[:name] }, page2[:tags].map { |t| t[:name] }
  end
end

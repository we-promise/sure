require "test_helper"

class Assistant::Function::GetMerchantsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::GetMerchants.new(@user)
  end

  test "has correct name" do
    assert_equal "get_merchants", @fn.name
  end

  test "has a description" do
    assert_not_empty @fn.description
  end

  test "is not in strict mode" do
    refute @fn.to_definition[:strict]
  end

  test "returns family merchants with ids and source" do
    result = @fn.call

    netflix = result[:merchants].find { |m| m[:name] == "Netflix" }

    assert_not_nil netflix
    assert_equal merchants(:netflix).id, netflix[:id]
    assert_equal "family", netflix[:source]
  end

  test "filters by search substring case-insensitively" do
    result = @fn.call("search" => "netfl")

    assert_equal [ "Netflix" ], result[:merchants].map { |m| m[:name] }
  end

  test "honors and clamps page_size" do
    result = @fn.call("page_size" => 1)

    assert_equal 1, result[:page_size]
    assert_equal 1, result[:merchants].size
    assert result[:total_pages] > 1
  end

  test "does not return another family's merchants" do
    foreign_user = users(:empty)

    result = Assistant::Function::GetMerchants.new(foreign_user).call

    assert_empty result[:merchants].map { |m| m[:name] } & @family.merchants.pluck(:name)
  end
end

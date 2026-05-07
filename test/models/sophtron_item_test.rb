require "test_helper"

class SophtronItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = @family.sophtron_items.create!(
      name: "Sophtron",
      user_id: "developer-user",
      access_key: Base64.strict_encode64("secret-key")
    )
  end

  test "ensure_customer reuses persisted customer id" do
    @item.update!(customer_id: "cust-existing")
    provider = mock
    provider.expects(:list_customers).never

    assert_equal "cust-existing", @item.ensure_customer!(provider: provider)
  end

  test "ensure_customer reuses matching listed customer" do
    provider = mock
    provider.expects(:list_customers).returns([
      { CustomerID: "cust-1", CustomerName: @item.generated_customer_name }
    ])
    provider.expects(:create_customer).never

    assert_equal "cust-1", @item.ensure_customer!(provider: provider)
    assert_equal "cust-1", @item.customer_id
    assert_equal @item.generated_customer_name, @item.customer_name
  end

  test "ensure_customer creates customer when no matching customer exists" do
    provider = mock
    provider.expects(:list_customers).returns([])
    provider.expects(:create_customer)
      .with(unique_id: @item.generated_customer_unique_id, name: @item.generated_customer_name, source: "Sure")
      .returns({ CustomerID: "cust-new", CustomerName: @item.generated_customer_name })

    assert_equal "cust-new", @item.ensure_customer!(provider: provider)
    assert_equal "cust-new", @item.customer_id
  end
end

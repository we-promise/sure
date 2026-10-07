require "test_helper"
require "ostruct"

class Family::PlaidConnectableTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @provider = mock
    Provider::Registry.stubs(:plaid_provider_for_region).with(:us).returns(@provider)
  end

  test "create_plaid_item! persists the institution id it is given" do
    stub_exchange

    item = @family.create_plaid_item!(
      public_token: "public-sandbox-1234",
      item_name: "Example Bank",
      region: :us,
      institution_id: "ins_example"
    )

    assert_equal "ins_example", item.institution_id
  end

  # institution_id is optional because this is a public model API and the column was
  # only ever populated during the first sync, by upsert_plaid_institution_snapshot!.
  # A caller that does not have the Link metadata must still be able to create an item.
  test "create_plaid_item! works without an institution id" do
    stub_exchange

    item = @family.create_plaid_item!(
      public_token: "public-sandbox-1234",
      item_name: "Example Bank",
      region: :us
    )

    assert_nil item.institution_id
    assert_equal "Example Bank", item.name
  end

  private
    def stub_exchange
      @provider.expects(:exchange_public_token).returns(
        OpenStruct.new(access_token: "access-sandbox-1234", item_id: "item-sandbox-#{SecureRandom.hex(4)}")
      )
    end
end

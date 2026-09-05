require "test_helper"

class Provider::WiseAdapterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @wise_item = wise_items(:one)
  end

  test "build_provider threads sca_private_key through to Provider::Wise" do
    key = OpenSSL::PKey::RSA.new(2048).to_pem
    @wise_item.update!(sca_private_key: key)

    provider = Provider::WiseAdapter.build_provider(family: @family, wise_item_id: @wise_item.id)

    assert_instance_of Provider::Wise, provider
    assert_equal @wise_item.token, provider.token
    assert_equal key, provider.sca_private_key
  end

  test "build_provider passes a nil sca_private_key when no keypair is configured" do
    provider = Provider::WiseAdapter.build_provider(family: @family, wise_item_id: @wise_item.id)

    assert_instance_of Provider::Wise, provider
    assert_nil provider.sca_private_key
  end

  test "build_provider resolves the family's most recent active item when wise_item_id is omitted" do
    provider = Provider::WiseAdapter.build_provider(family: @family)

    assert_instance_of Provider::Wise, provider
    assert_equal @wise_item.token, provider.token
  end

  test "build_provider returns nil without a family" do
    assert_nil Provider::WiseAdapter.build_provider(family: nil)
  end

  test "build_provider returns nil when credentials are not configured" do
    @wise_item.update_column(:token, "")

    assert_nil Provider::WiseAdapter.build_provider(family: @family, wise_item_id: @wise_item.id)
  end
end

require "test_helper"

class Provider::FioAdapterTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @first = FioItem.create!(family: @family, name: "Current", token: "token-one")
    @second = FioItem.create!(family: @family, name: "Savings", token: "token-two")
  end

  test "builds a client for the requested connection" do
    provider = Provider::FioAdapter.build_provider(family: @family, fio_item_id: @second.id)

    assert_equal "token-two", provider.token
  end

  # One token reaches one account, so a family holds a connection per account. Falling
  # back to another one would hand the caller a client for the wrong account.
  test "refuses to substitute another connection for an unknown id" do
    assert_nil Provider::FioAdapter.build_provider(family: @family, fio_item_id: SecureRandom.uuid)
  end

  test "picks the first configured connection when none is requested" do
    provider = Provider::FioAdapter.build_provider(family: @family)

    assert_equal @second.token, provider.token, "ordered is newest-first"
  end
end

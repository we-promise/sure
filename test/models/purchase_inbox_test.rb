require "test_helper"

class PurchaseInboxTest < ActiveSupport::TestCase
  test "an empty or missing port variable means the IMAPS port" do
    assert_equal 993, PurchaseInbox.env_port(nil)
    assert_equal 993, PurchaseInbox.env_port("")
    assert_equal 993, PurchaseInbox.env_port(" ")
    assert_equal 143, PurchaseInbox.env_port("143")
  end

  test "TLS stays on unless the variable explicitly turns it off" do
    assert PurchaseInbox.env_ssl(nil)
    assert PurchaseInbox.env_ssl("")
    assert PurchaseInbox.env_ssl("true")
    assert PurchaseInbox.env_ssl("yes")
    assert_not PurchaseInbox.env_ssl("false")
    assert_not PurchaseInbox.env_ssl(" FALSE ")
  end
end

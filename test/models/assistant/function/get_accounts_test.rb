require "test_helper"

class Assistant::Function::GetAccountsTest < ActiveSupport::TestCase
  test "returns stable ids and write capability for transaction actions" do
    user = users(:family_member)
    result = Assistant::Function::GetAccounts.new(user).call

    checking = result[:accounts].find { |account| account[:name] == accounts(:depository).name }
    credit_card = result[:accounts].find { |account| account[:name] == accounts(:credit_card).name }

    assert_equal accounts(:depository).id, checking[:id]
    assert_equal true, checking[:writable]
    assert_equal "full_control", checking[:permission]

    assert_equal accounts(:credit_card).id, credit_card[:id]
    assert_equal false, credit_card[:writable]
    assert_equal "read_only", credit_card[:permission]
  end

  test "does not advertise disabled accounts for new actions" do
    user = users(:family_admin)
    disabled = accounts(:depository)
    disabled.update!(status: "disabled")

    result = Assistant::Function::GetAccounts.new(user).call

    assert_not_includes result[:accounts].pluck(:id), disabled.id
  end
end

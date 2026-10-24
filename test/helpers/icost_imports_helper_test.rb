require "test_helper"
require "ostruct"

class IcostImportsHelperTest < ActionView::TestCase
  setup do
    Current.session = sessions(:one)
  end

  teardown { Current.reset }

  test "source fields preserve unknown, duplicate and unnamed columns" do
    record = OpenStruct.new(icost_import: OpenStruct.new(headers: [ "Notes", "Future", "Future" ]), source_values: [ "", false, "unknown", "extra" ])
    fields = icost_source_fields(record)
    assert_equal 4, fields.length
    assert_equal "2. Future", fields[1][0]
    assert_equal "false", fields[1][1]
    assert_equal "3. Future", fields[2][0]
    assert_equal "4. Unnamed column 4", fields[3][0]
    assert_equal "extra", fields[3][1]
  end

  test "financial decimals are rendered without float rounding" do
    assert_equal "1234567890123.1234", icost_value(BigDecimal("1234567890123.1234"))
    assert_equal "0.0", icost_value(BigDecimal("0"))
  end

  test "record metadata cannot reveal an inaccessible transfer counterpart" do
    user = users(:family_member)
    user.account_shares.destroy_all
    Current.session = user.sessions.create!
    source = OpenStruct.new(user_id: users(:family_admin).id)
    record = OpenStruct.new(family_id: user.family_id, icost_import: source,
                            entry: entries(:transfer_out), counterpart_entry: entries(:transfer_in))
    refute icost_record_visible?(record)
    accounts(:depository).account_shares.create!(user: user, permission: "read_only")
    refute icost_record_visible?(record)
    accounts(:credit_card).account_shares.create!(user: user, permission: "read_only")
    assert icost_record_visible?(record)
  end

  test "source owner can view their original source without a ledger entry" do
    user = Current.user
    record = OpenStruct.new(family_id: user.family_id, icost_import: OpenStruct.new(user_id: user.id))
    assert icost_record_visible?(record)
    record.family_id = families(:empty).id
    refute icost_record_visible?(record)
  end
end

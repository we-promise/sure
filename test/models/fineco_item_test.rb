require "test_helper"

class FinecoItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    Current.reset
  end

  teardown { Current.reset }

  test "Fineco is tenant-wide and remains admin-only" do
    assert_equal :tenant_wide, FinecoItem.declared_credential_scope
    assert_not FinecoItem.member_connectable?
  end

  test "owner defaults to the current user" do
    Current.session = @admin.sessions.create!
    item = @family.fineco_items.build

    item.valid?

    assert_equal @admin, item.owner
  end

  test "owner must belong to the same family" do
    item = @family.fineco_items.new(owner: users(:empty))

    assert_not item.valid?
    assert_includes item.errors[:owner], "is invalid"
  end

  test "captured credentials are rejected when explicit encryption is unavailable" do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)
    item = build_item

    assert_not item.save
    assert_includes item.errors.details[:base].map { |error| error[:error] }, :encryption_unavailable
    assert_not item.persisted?
  end

  test "session credentials are encrypted at rest without deterministic lookup" do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    item = build_item
    cookie = item.gsessionid

    item.save!

    stored_values = ActiveRecord::Base.connection.select_one(
      "SELECT gsessionid, account_index, dossier_index FROM fineco_items WHERE id = #{ActiveRecord::Base.connection.quote(item.id)}"
    )
    reloaded = item.reload

    {
      "gsessionid" => cookie,
      "account_index" => "2",
      "dossier_index" => "3"
    }.each do |attribute, cleartext|
      refute_equal cleartext, stored_values.fetch(attribute)
      assert_equal cleartext, reloaded.public_send(attribute)
      encrypted_type = FinecoItem.type_for_attribute(attribute)
      refute_equal cleartext, encrypted_type.serialize(cleartext)
    end
  end

  test "reconnect must retain the account and dossier selected on initial login" do
    assert build_item(account_index: "2", dossier_index: "3").same_account_context?(account_index: "2", dossier_index: "3")
    assert_not build_item(account_index: "2", dossier_index: "3").same_account_context?(account_index: "4", dossier_index: "3")
    assert_not build_item(account_index: "2", dossier_index: "3").same_account_context?(account_index: "2", dossier_index: "5")
  end

  test "credentials are configured only when the captured bank session is complete" do
    item = build_item
    assert item.credentials_configured?

    item.gsessionid = nil

    assert_not item.credentials_configured?
  end

  private

    def build_item(account_index: "2", dossier_index: "3")
      FinecoItem.new(
        family: @family,
        owner: @admin,
        gsessionid: "session-cookie-secret",
        account_index: account_index,
        dossier_index: dossier_index,
        bank_account_number: "SYNTHETIC-ACCOUNT",
        dossier_identity: Digest::SHA256.hexdigest("synthetic-dossier"),
        captured_at: Time.current
      )
    end
end

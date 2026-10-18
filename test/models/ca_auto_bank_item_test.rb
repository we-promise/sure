require "test_helper"
require Rails.root.join("test/support/ca_auto_bank_test_helper")

class CaAutoBankItemTest < ActiveSupport::TestCase
  include CaAutoBankTestHelper

  setup do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
  end

  test "credentials are encrypted and unavailable without explicit encryption" do
    item = ca_connected_item
    stored = ActiveRecord::Base.connection.select_one("SELECT authentication_token, account_identity FROM ca_auto_bank_items WHERE id = #{ActiveRecord::Base.connection.quote(item.id)}")
    refute_equal item.authentication_token, stored.fetch("authentication_token")
    refute_equal item.account_identity, stored.fetch("account_identity")
    assert item.ready_for_sync?
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)
    refute item.ready_for_sync?
    assert_not item.valid?
  end

  test "expiry removes a connection from sync selection without deleting its saved account data" do
    item = ca_connected_item
    travel 61.minutes do
      refute item.session_configured?
      assert item.reconnect_required?
      refute CaAutoBankItem.syncable.exists?(item.id)
    end
    item.disconnect!
    assert_nil item.reload.authentication_token
    assert_equal 2, item.connection_generation
    assert_equal "synthetic-partner", item.account_identity
  end

  test "only an active owner in the same family can provide a ready connection" do
    item = ca_connected_item
    item.owner = users(:empty)
    refute item.valid?
    refute item.ready_for_sync?
    assert_equal :tenant_wide, CaAutoBankItem.declared_credential_scope
    refute CaAutoBankItem.member_connectable?
  end

  test "a failed connection does not prevent its owner from accepting a family invitation" do
    leaver = users(:empty)
    item = CaAutoBankItem.create!(family: leaver.family, owner: leaver)
    inviter = users(:family_admin)
    invitation = inviter.family.invitations.create!(email: leaver.email, role: "member", inviter: inviter)

    assert invitation.accept_for(leaver)
    assert_equal inviter.family_id, leaver.reload.family_id
    refute CaAutoBankItem.exists?(item.id)
  end

  test "bulk and scheduled family syncs cannot dispatch this owner-only preview" do
    item = ca_connected_item
    assert item.ready_for_sync?
    assert_empty CaAutoBankItem.syncable
    CaAutoBankItem.any_instance.expects(:sync_later).never
    sync = item.family.syncs.create!
    Family::Syncer.new(item.family).perform_sync(sync)
  end
end

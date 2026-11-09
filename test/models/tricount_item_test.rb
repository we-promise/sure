# frozen_string_literal: true

require "test_helper"
require_relative "../support/tricount_test_helper"

class TricountItemTest < ActiveSupport::TestCase
  include TricountTestHelper

  # Self-hosted installs often run on keys derived from SECRET_KEY_BASE, with
  # no credentials block or key variables; a check for those alone left the
  # sharing links, which grant write access, in plaintext there.
  test "encryption follows the app's readiness check, derived keys included" do
    ActiveRecordEncryptionConfig.stubs(:ready?).returns(true)
    assert TricountItem.encryption_ready?

    ActiveRecordEncryptionConfig.stubs(:ready?).returns(false)
    assert_not TricountItem.encryption_ready?
  end

  # The snapshots hold the members' names and every expense.
  test "a tricount's stored snapshots are encrypted" do
    skip "Encryption not configured" unless ActiveRecordEncryptionConfig.ready?

    item = families(:empty).tricount_items.create!(name: "Tricount", sharing_tokens: SHARING_TOKEN)
    tricount_account = item.tricount_accounts.new
    tricount_account.upsert_from_tricount!(tricount_registry)

    assert_equal [ "Alex", "Sam", "Kim" ], tricount_account.reload.members.map(&:name)
    { raw_payload: "Weekend trip", raw_transactions_payload: "Dinner" }.each do |column, value|
      raw = ActiveRecord::Base.connection.select_value(TricountAccount.where(id: tricount_account.id).select(column).to_sql)
      assert_not_includes raw.to_s, value, "TricountAccount##{column} should be encrypted at rest"
    end
  end

  test "sharing links and the session are stored encrypted" do
    skip "Encryption not configured" unless ActiveRecordEncryptionConfig.ready?

    item = families(:empty).tricount_items.create!(name: "Tricount", sharing_tokens: SHARING_TOKEN, session_token: "session-plaintext-probe")

    assert_equal [ SHARING_TOKEN, "session-plaintext-probe" ], item.reload.values_at(:sharing_tokens, :session_token)
    [ [ :sharing_tokens, SHARING_TOKEN ], [ :session_token, "session-plaintext-probe" ] ].each do |column, value|
      raw = ActiveRecord::Base.connection.select_value(TricountItem.where(id: item.id).select(column).to_sql)
      assert_not_includes raw.to_s, value, "TricountItem##{column} should be encrypted at rest"
    end
  end
end

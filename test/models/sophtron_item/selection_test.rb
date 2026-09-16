require "test_helper"
require_relative "../../support/sophtron_fixture_fence_helper"

class SophtronItem::SelectionTest < ActiveSupport::TestCase
  include SophtronFixtureFenceHelper

  setup do
    @item = families(:dylan_family).sophtron_items.create!(name: "Picker source", user_id: "secret-user",
      access_key: "secret-access", customer_id: "secret-customer", user_institution_id: "secret-institution")
  end

  test "signed selection contains IDs flow and fingerprint without raw connection data" do
    token = SophtronItem::Selection.issue(@item, flow: :link_existing_account, account_id: accounts(:depository).id)
    claims = Rails.application.message_verifier(SophtronItem::Selection::PURPOSE).verified(token, purpose: SophtronItem::Selection::PURPOSE)
    assert_equal %w[account_id family_id fingerprint flow item_id], claims.keys.sort
    assert_equal accounts(:depository).id, claims["account_id"]
    assert_match(/\A[0-9a-f]{64}\z/, claims["fingerprint"])
    assert_not claims.to_s.include?("secret-")
    selection = SophtronItem::Selection.from_token(token, flow: :link_existing_account, account_id: accounts(:depository).id)
    assert_equal @item.id, selection.item_for(@item.family).id
    assert_equal @item.id, selection.verify!(@item).id
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal "[FILTERED]", filter.filter(selection_token: token)[:selection_token]
  end

  test "missing malformed and tampered selections are rejected" do
    token = SophtronItem::Selection.issue(@item, flow: :link_accounts)
    tampered = token[0...-1] + (token.end_with?("0") ? "1" : "0")
    [ nil, "", "untrusted", "x" * 8193, tampered ].each do |value|
      assert_raises(SophtronItem::Selection::Invalid) { SophtronItem::Selection.from_token(value, flow: :link_accounts) }
    end
  end

  test "selection expires after the picker lifetime" do
    token = SophtronItem::Selection.issue(@item, flow: :link_accounts)
    travel SophtronItem::Selection::LIFETIME + 1.second do
      assert_raises(SophtronItem::Selection::Invalid) { SophtronItem::Selection.from_token(token, flow: :link_accounts) }
    end
  end

  test "selection cannot change flow financial account or family" do
    token = SophtronItem::Selection.issue(@item, flow: :link_existing_account, account_id: accounts(:depository).id)
    assert_raises(SophtronItem::Selection::Invalid) { SophtronItem::Selection.from_token(token, flow: :link_accounts) }
    assert_raises(SophtronItem::Selection::Invalid) do
      SophtronItem::Selection.from_token(token, flow: :link_existing_account, account_id: accounts(:investment).id)
    end
    selection = SophtronItem::Selection.from_token(token, flow: :link_existing_account, account_id: accounts(:depository).id)
    assert_raises(SophtronItem::Selection::Invalid) { selection.item_for(families(:empty)) }
  end

  test "fresh credentials customer institution endpoint job and deletion state invalidate old selection" do
    changes = { user_id: "replacement-user", access_key: "replacement-key", customer_id: "replacement-customer",
      user_institution_id: "replacement-institution", base_url: "https://example.com/api",
      institution_id: "replacement-bank", current_job_id: "replacement-job", scheduled_for_deletion: true }
    changes.each do |attribute, value|
      token = SophtronItem::Selection.issue(@item.reload, flow: :link_accounts)
      selection = SophtronItem::Selection.from_token(token, flow: :link_accounts)
      SophtronItem.find(@item.id).update!(attribute => value)
      assert_raises(SophtronItem::Selection::Invalid) { selection.verify!(@item) }
    end
  end

  test "a fresh token cannot validate a different receiver retained by an outer permit" do
    old = @item.reload
    SophtronItem.find(old.id).update!(access_key: "current-key")
    token = SophtronItem::Selection.issue(SophtronItem.find(old.id), flow: :link_accounts)
    selection = SophtronItem::Selection.from_token(token, flow: :link_accounts)
    old.update!(access_key: "old-key")
    SophtronItem::LegacyAccess.with_item(old, operation: :lifecycle) do |admitted|
      SophtronItem.find(old.id).update!(access_key: "current-key")
      assert_raises(SophtronItem::Selection::Invalid) { selection.verify!(admitted) }
    end
  end
end

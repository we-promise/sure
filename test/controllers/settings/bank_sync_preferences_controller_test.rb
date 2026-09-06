require "test_helper"

class Settings::BankSyncPreferencesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @plaid_item = plaid_items(:one)
  end

  test "enabling the preference clears plaid cursors and re-syncs the family's items" do
    @plaid_item.update!(next_cursor: "cursor-before-change")

    assert_enqueued_with(job: SyncJob) do
      patch settings_bank_sync_preferences_url,
            params: { family: { plaid_prefer_original_description: "1" } }
    end

    assert_redirected_to settings_providers_url
    assert @family.reload.plaid_prefer_original_description?
    assert_nil @plaid_item.reload.next_cursor
  end

  test "saving the same value does not force a re-sync" do
    @plaid_item.update!(next_cursor: "cursor-unchanged")

    assert_no_enqueued_jobs(only: SyncJob) do
      patch settings_bank_sync_preferences_url,
            params: { family: { plaid_prefer_original_description: "0" } }
    end

    refute @family.reload.plaid_prefer_original_description?
    assert_equal "cursor-unchanged", @plaid_item.reload.next_cursor
  end

  # The whole reason this preference lives on Family rather than in the
  # instance-wide provider settings: one family's choice must not reach another.
  test "the preference and its re-sync are scoped to the current family" do
    other_family = families(:empty)
    other_item = PlaidItem.create!(
      family: other_family,
      name: "Other Family Bank",
      plaid_id: "item_other_family",
      access_token: "other_family_token",
      next_cursor: "other-family-cursor"
    )

    patch settings_bank_sync_preferences_url,
          params: { family: { plaid_prefer_original_description: "1" } }

    assert_redirected_to settings_providers_url
    assert @family.reload.plaid_prefer_original_description?

    refute other_family.reload.plaid_prefer_original_description?
    assert_equal "other-family-cursor", other_item.reload.next_cursor
    assert_empty other_item.syncs
  end

  test "non-admin members cannot change the preference" do
    sign_in users(:family_member)

    patch settings_bank_sync_preferences_url,
          params: { family: { plaid_prefer_original_description: "1" } }

    assert_redirected_to root_path
    refute @family.reload.plaid_prefer_original_description?
  end
end

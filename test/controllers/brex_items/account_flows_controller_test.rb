# frozen_string_literal: true

require "test_helper"

class BrexItems::AccountFlowsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)

    @family = families(:dylan_family)
    @brex_item = BrexItem.create!(
      family: @family,
      name: "Business Brex",
      token: "link_auth_brex_token",
      base_url: "https://api.brex.com"
    )
  end

  include ProviderLinkAuthorizationTests
  provider_link_authorization_tests(
    select_url: :select_existing_account_brex_items_url,
    link_url: :link_existing_account_brex_items_url,
    target: ->(owner) {
      @family.accounts.create!(owner: owner, name: "Manual Checking", balance: 0, currency: "USD",
                               accountable: Depository.new)
    },
    # The flow takes the upstream Brex id as brex_account_id, and the shared
    # tests submit the record id, so the two are made equal.
    provider_account: -> {
      record = @brex_item.brex_accounts.create!(name: "Brex Cash", account_id: SecureRandom.hex(6),
                                                account_kind: "cash", currency: "USD")
      record.update!(account_id: record.id)
      record
    },
    provider_param: :brex_account_id,
    params: -> { { brex_item_id: @brex_item.id } },
    # Serve the accounts API response from the records, plus one never linked
    # so select has something to list; no request reaches Brex.
    prepare: -> {
      ids = @brex_item.brex_accounts.pluck(:account_id) + [ "unlinked_brex_account" ]
      payload = ids.map do |id|
        { id: id, name: "Brex Cash #{id}", account_kind: "cash", status: "active",
          current_balance: { amount: 100_000, currency: "USD" } }
      end
      BrexItem::AccountFlow.any_instance.stubs(:accounts).returns(payload)
      Provider::Brex.expects(:new).never
    }
  )
end

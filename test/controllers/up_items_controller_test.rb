require "test_helper"

class UpItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)

    @family = families(:dylan_family)
    @up_item = UpItem.create!(family: @family, name: "Main Up", access_token: "up-access-token")
  end

  include ProviderLinkAuthorizationTests
  provider_link_authorization_tests(
    select_url: :select_existing_account_up_items_url,
    link_url: :link_existing_account_up_items_url,
    target: ->(owner) {
      @family.accounts.create!(owner: owner, name: "Manual Checking", balance: 0, currency: "AUD",
                               accountable: Depository.create!(subtype: "checking"))
    },
    provider_account: -> {
      @up_item.up_accounts.create!(name: "Up Spending", account_id: SecureRandom.hex(6), currency: "AUD")
    },
    provider_param: :up_account_id,
    params: -> { { up_item_id: @up_item.id } },
    prepare: -> { UpItemsController.any_instance.stubs(:fetch_up_accounts_from_api).returns(nil) }
  )
end

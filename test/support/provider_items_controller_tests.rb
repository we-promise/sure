# frozen_string_literal: true

# Controller contract for an account provider on the provider kit, the
# integration-test half of ProviderItemLifecycleTests. Include it in an
# integration test that defines `provider_item` (a connection with at least one
# provider account, in the family of users(:family_admin) and
# users(:family_member)).
module ProviderItemsControllerTests
  extend ActiveSupport::Concern

  ACCOUNT_FLOW_ROUTES = {
    "preload_accounts" => :get,
    "select_accounts" => :get,
    "link_accounts" => :post,
    "select_existing_account" => :get,
    "link_existing_account" => :post
  }.freeze

  included do
    test "provider kit: the shared controller serves the connection's routes at their usual paths" do
      key = provider_item.provider_key

      ACCOUNT_FLOW_ROUTES.each do |action, verb|
        path = provider_routes.public_send(:"#{action}_#{key}_items_path")
        assert_equal "/#{key}_items/#{action}", path
        assert_equal({ controller: "#{key}_items", action: action }, Rails.application.routes.recognize_path(path, method: verb))
      end

      sync_path = provider_routes.public_send(:"sync_#{key}_item_path", provider_item)
      assert_equal "/#{key}_items/#{provider_item.id}/sync", sync_path
      assert_equal({ controller: "#{key}_items", action: "sync", id: provider_item.id.to_s }, Rails.application.routes.recognize_path(sync_path, method: :post))
      assert_operator "#{key}_items_controller".camelize.constantize, :<, ProviderItemsController
    end

    test "provider kit: a member who is not an admin can neither change the connection nor link accounts" do
      sign_in users(:family_member)
      key = provider_item.provider_key
      item_path = provider_routes.public_send(:"#{key}_item_path", provider_item)
      requests = ACCOUNT_FLOW_ROUTES.map { |action, verb| [ verb, "/#{key}_items/#{action}" ] } +
        [ [ :get, "/#{key}_items/new" ], [ :post, "/#{key}_items" ], [ :get, "#{item_path}/edit" ] ] +
        [ [ :post, "#{item_path}/sync" ], [ :patch, item_path ], [ :delete, item_path ] ]

      assert_no_difference [ "Account.count", "AccountProvider.count", "Sync.count", "#{provider_item.class.name}.count" ] do
        requests.each do |verb, path|
          public_send(verb, path, params: { account_id: provider_item.family.accounts.first&.id, "#{key}_item": { name: "Renamed" } })

          assert_kind_of ProviderItemsController, @controller, "#{verb} #{path}"
          assert_redirected_to accounts_path
          assert_equal I18n.t("shared.require_admin"), flash[:alert], "#{verb} #{path}"
        end
      end

      provider_item.reload
      assert_not_equal "Renamed", provider_item.name
      assert_not provider_item.scheduled_for_deletion?
    end

    test "provider kit: syncing a connection that is already syncing starts nothing" do
      sign_in users(:family_admin)
      provider_item.class.any_instance.stubs(:syncing?).returns(true)
      provider_item.class.any_instance.expects(:sync_later).never

      post provider_routes.public_send(:"sync_#{provider_item.provider_key}_item_path", provider_item)

      assert_redirected_to accounts_path
    end

    test "provider kit: removing a connection unlinks its accounts and schedules its deletion" do
      sign_in users(:family_admin)
      provider_account = provider_item.provider_accounts.first
      account = provider_item.family.accounts.create!(name: "Linked", balance: 0, currency: "USD", accountable: Depository.new)
      link = AccountProvider.create!(account: account, provider: provider_account)

      delete provider_routes.public_send(:"#{provider_item.provider_key}_item_path", provider_item)

      assert_redirected_to accounts_path
      assert_not AccountProvider.exists?(link.id)
      assert Account.exists?(account.id)
      assert provider_item.reload.scheduled_for_deletion?
    end
  end

  private
    def provider_routes
      Rails.application.routes.url_helpers
    end
end

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
      { "setup_accounts" => :get, "complete_account_setup" => :post }.each do |action, verb|
        path = provider_routes.public_send(:"#{action}_#{key}_item_path", provider_item)
        assert_equal "/#{key}_items/#{provider_item.id}/#{action}", path
        assert_equal({ controller: "#{key}_items", action: action, id: provider_item.id.to_s }, Rails.application.routes.recognize_path(path, method: verb))
      end
      assert_operator "#{key}_items_controller".camelize.constantize, :<, ProviderItemsController
    end

    test "provider kit: a member who is not an admin can neither change the connection nor link accounts" do
      sign_in users(:family_member)
      key = provider_item.provider_key
      item_path = provider_routes.public_send(:"#{key}_item_path", provider_item)
      requests = ACCOUNT_FLOW_ROUTES.map { |action, verb| [ verb, "/#{key}_items/#{action}" ] } +
        [ [ :post, "#{item_path}/sync" ], [ :patch, item_path ], [ :delete, item_path ],
          [ :get, "#{item_path}/setup_accounts" ], [ :post, "#{item_path}/complete_account_setup" ] ]

      assert_no_difference [ "Account.count", "AccountProvider.count", "Sync.count" ] do
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

    test "provider kit: the setup page lists the connection's accounts that are not linked yet" do
      sign_in users(:family_admin)
      provider_item.class::AccountFlow.any_instance.stubs(:fetch_accounts).returns([])
      unlinked = provider_item.provider_accounts.first
      linked = unlinked.dup.tap { |account| account.update!(account_id: "#{unlinked.account_id}-linked", name: "Already linked account") }
      AccountProvider.create!(account: provider_item.family.accounts.create!(name: "Manual", balance: 0, currency: "USD", accountable: Depository.new), provider: linked)

      get provider_routes.public_send(:"setup_accounts_#{provider_item.provider_key}_item_path", provider_item)

      assert_response :success
      assert_includes response.body, unlinked.name
      assert_not_includes response.body, linked.name
    end

    test "provider kit: completing setup links only this connection's accounts, with supported types and subtypes" do
      sign_in users(:family_admin)
      provider_item.class.any_instance.stubs(:sync_later)
      own = provider_item.provider_accounts.first
      unsupported = own.dup.tap { |account| account.update!(account_id: "#{own.account_id}-unsupported") }
      foreign = foreign_provider_account
      supported_type = provider_item.class::AccountFlow.adapter_class.supported_account_types.first
      unsupported_type = (Accountable::TYPES - provider_item.class::AccountFlow.adapter_class.supported_account_types).first

      assert_difference [ "Account.count", "AccountProvider.count" ], 1 do
        post provider_routes.public_send(:"complete_account_setup_#{provider_item.provider_key}_item_path", provider_item),
             params: {
               account_types: { own.id => supported_type, unsupported.id => unsupported_type, foreign.id => supported_type },
               account_subtypes: { own.id => "not-a-subtype" }
             },
             headers: { "Turbo-Frame" => "modal" }
      end

      assert_response :success
      assert_includes response.body, %(target="#{ActionView::RecordIdentifier.dom_id(provider_item)}")
      account = own.reload.account
      assert_equal supported_type, account.accountable_type
      assert_not_equal "not-a-subtype", account.accountable.subtype
      assert_nil unsupported.reload.account_provider
      assert_nil foreign.reload.account_provider
    end
  end

  private
    # A provider account of the same provider that belongs to another connection.
    def foreign_provider_account
      other_item = provider_item.dup.tap { |item| item.save!(validate: false) }
      item_association = provider_item.provider_accounts.klass.reflect_on_all_associations(:belongs_to).find { |reflection| reflection.klass == provider_item.class }
      provider_item.provider_accounts.first.dup.tap do |account|
        account.public_send(:"#{item_association.name}=", other_item)
        account.update!(account_id: "foreign-#{SecureRandom.hex(4)}")
      end
    end

    def provider_routes
      Rails.application.routes.url_helpers
    end
end

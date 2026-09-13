# Shared authorization tests for a provider's select_existing_account and
# link_existing_account actions (#3534). The including test must sign in
# users(:family_admin); the linked-to accounts belong to users(:family_member).
#
#   include ProviderLinkAuthorizationTests
#   provider_link_authorization_tests(
#     select_url: :select_existing_account_foo_items_url,
#     link_url: :link_existing_account_foo_items_url,
#     target: ->(owner) { account this provider may link to, owned by owner },
#     provider_account: -> { a new, unlinked provider account },
#     provider_param: :foo_account_id,
#     params: -> { { foo_item_id: @foo_item.id } },   # optional
#     prepare: -> { stub provider API calls },        # optional, runs before each request
#     select_renders: true,                           # optional: writable select renders 200
#     relinks: false,                                 # link moves an existing link
#     dialog_names_linked: false                      # select lists linked accounts by name
#   )
#
# ProviderLinkAuthorizationCoverageTest fails for any link route whose
# controller test does not call this.
module ProviderLinkAuthorizationTests
  extend ActiveSupport::Concern

  REFUSED_SHARES = { "no share" => nil, "read_only" => "read_only", "read_write" => "read_write" }.freeze

  included do
    include ActiveJob::TestHelper
  end

  class_methods do
    def provider_link_authorization_tests(select_url:, link_url:, target:, provider_account:, provider_param:,
                                          params: -> { {} }, prepare: -> { }, select_renders: true,
                                          relinks: false, dialog_names_linked: false)
      config = { select_url:, link_url:, target:, provider_account:, provider_param:, params:, prepare: }
      define_method(:provider_link_config) { config }

      REFUSED_SHARES.each do |label, permission|
        test "select_existing_account refuses an admin with #{label} on the account" do
          account = provider_link_member_account(permission)

          get provider_link_url(:select_url), params: provider_link_params.merge(account_id: account.id)

          assert_provider_link_refused
        end

        test "link_existing_account refuses an admin with #{label} on the account" do
          account = provider_link_member_account(permission)
          provider_record = provider_link_new_provider_account

          assert_no_difference [ "AccountProvider.count", "Sync.count" ] do
            post provider_link_url(:link_url), params: provider_link_link_params(account, provider_record)
          end

          assert_provider_link_refused
          assert_nil provider_record.reload.account_provider
        end
      end

      test "link_existing_account answers json with 403 for an account the admin cannot write" do
        account = provider_link_member_account("read_write")
        provider_record = provider_link_new_provider_account

        assert_no_difference "AccountProvider.count" do
          post provider_link_url(:link_url), params: provider_link_link_params(account, provider_record), as: :json
        end

        assert_response :forbidden
        assert_equal I18n.t("accounts.not_authorized"), response.parsed_body["error"]
      end

      # The modal's form submits as turbo_stream. With no Referer the refusal
      # used to emit a redirect stream with no URL, leaving the dialog open.
      test "link_existing_account refuses a turbo_stream request without a referer" do
        account = provider_link_member_account("read_write")
        provider_record = provider_link_new_provider_account

        assert_no_difference "AccountProvider.count" do
          post provider_link_url(:link_url), params: provider_link_link_params(account, provider_record),
               headers: { "Accept" => "text/vnd.turbo-stream.html" }
        end

        assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
        assert_includes response.body, %(<turbo-stream action="redirect" target="#{accounts_path}">)
      end

      test "an admin with full_control on the account can select and link it" do
        account = provider_link_member_account("full_control")
        provider_record = provider_link_new_provider_account

        get provider_link_url(:select_url), params: provider_link_params.merge(account_id: account.id)
        if select_renders
          assert_response :success
        else
          refute_equal I18n.t("accounts.not_authorized"), flash[:alert]
        end

        assert_difference "AccountProvider.count", 1 do
          post provider_link_url(:link_url), params: provider_link_link_params(account, provider_record)
        end
        assert_equal account, provider_record.reload.account_provider.account
      end

      return unless relinks

      REFUSED_SHARES.slice("no share", "read_write").each do |label, permission|
        test "link_existing_account refuses to move a link off an account the admin holds #{label} on" do
          holder = provider_link_member_account(permission)
          provider_record = provider_link_new_provider_account
          AccountProvider.create!(account: holder, provider: provider_record)
          target_account = provider_link_admin_account

          assert_no_enqueued_jobs(only: DestroyJob) do
            assert_no_difference "AccountProvider.count" do
              post provider_link_url(:link_url), params: provider_link_link_params(target_account, provider_record)
            end
          end

          assert_provider_link_refused
          assert_equal holder, provider_record.reload.account_provider.account
          refute holder.reload.pending_deletion?
        end
      end

      test "link_existing_account moves a link off an account the admin can write" do
        holder = provider_link_admin_account
        provider_record = provider_link_new_provider_account
        AccountProvider.create!(account: holder, provider: provider_record)
        target_account = provider_link_admin_account

        post provider_link_url(:link_url), params: provider_link_link_params(target_account, provider_record)

        assert_equal target_account, provider_record.reload.account_provider.account
      end

      test "select_existing_account does not offer accounts linked to an account the admin cannot write" do
        hidden = provider_link_member_account(nil, name: "Hidden member account #{SecureRandom.hex(4)}")
        hidden_record = provider_link_new_provider_account
        AccountProvider.create!(account: hidden, provider: hidden_record)
        visible = provider_link_admin_account(name: "Visible admin account #{SecureRandom.hex(4)}")
        visible_record = provider_link_new_provider_account
        AccountProvider.create!(account: visible, provider: visible_record)
        target_account = provider_link_admin_account

        get provider_link_url(:select_url), params: provider_link_params.merge(account_id: target_account.id)

        assert_response :success
        refute_includes response.body, hidden.name
        assert_select %(input[value="#{hidden_record.id}"]), count: 0
        if dialog_names_linked
          assert_includes response.body, visible.name
          assert_select %(input[value="#{visible_record.id}"]), count: 1
        end
      end
    end
  end

  private
    # Every request goes through here, so `prepare` (stubs for provider API
    # calls the actions make) is in place before each one.
    def provider_link_url(key)
      instance_exec(&provider_link_config[:prepare])
      public_send(provider_link_config[key])
    end

    def provider_link_params
      instance_exec(&provider_link_config[:params])
    end

    def provider_link_link_params(account, provider_record)
      provider_link_params.merge(account_id: account.id, provider_link_config[:provider_param] => provider_record.id)
    end

    def provider_link_new_provider_account
      instance_exec(&provider_link_config[:provider_account])
    end

    def provider_link_admin_account(name: "Admin account #{SecureRandom.hex(4)}")
      account = instance_exec(users(:family_admin), &provider_link_config[:target])
      account.update!(name: name)
      account
    end

    # An account owned by family_member on which family_admin holds exactly
    # `permission` (nil: no share at all).
    def provider_link_member_account(permission, name: "Member account #{SecureRandom.hex(4)}")
      account = instance_exec(users(:family_member), &provider_link_config[:target])
      account.update!(name: name)
      account.account_shares.where(user: users(:family_admin)).destroy_all
      account.share_with!(users(:family_admin), permission: permission) if permission
      assert_equal permission&.to_sym, account.reload.permission_for(users(:family_admin))
      account
    end

    def assert_provider_link_refused
      assert_redirected_to accounts_path
      assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
    end
end

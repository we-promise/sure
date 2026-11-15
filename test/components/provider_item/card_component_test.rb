# frozen_string_literal: true

require "test_helper"

class ProviderItem::CardComponentTest < ActiveSupport::TestCase
  include ProviderItemSnapshots

  setup do
    travel_to Time.zone.parse("2026-11-15 12:00:00")
    @item = brex_items(:one)
    @item.class.any_instance.stubs(:last_synced_at).returns(3.hours.ago)
  end

  CASES = {
    "brex_card_admin" => { user: :family_admin, visible: :all },
    "brex_card_admin_with_linked_account" => { user: :family_admin, visible: :all, linked: true },
    "brex_card_member_with_accounts" => { user: :family_member, visible: :linked, linked: true },
    "brex_card_member_shown_one_of_two" => { user: :family_member, visible: :linked, linked: true, second_linked: true },
    "brex_card_member_without_accounts" => { user: :family_member, visible: :none },
    "brex_card_scheduled_for_deletion" => { user: :family_admin, visible: :all, deleting: true },
    "brex_card_sync_error" => { user: :family_admin, visible: :all, sync_error: "Token expired" }
  }.freeze

  CASES.each do |name, options|
    test "#{name}: the card partial renders as before" do
      assert_matches_provider_item_snapshot(name, render_card(options) { |visible| { partial: "brex_items/brex_item", locals: { brex_item: @item, visible_accounts: visible } } })
    end

    test "#{name}: the card component renders the same HTML" do
      assert_matches_provider_item_snapshot(name, render_card(options) { |visible| ProviderItem::CardComponent.new(item: @item, visible_accounts: visible) })
    end
  end

  private
    def render_card(options)
      Current.stubs(:user).returns(users(options[:user]))
      @item.update_columns(scheduled_for_deletion: true) if options[:deleting]
      @item.class.any_instance.stubs(:sync_error).returns(options[:sync_error]) if options[:sync_error]
      if options[:linked]
        account = @item.family.accounts.create!(name: "Brex Operating", balance: 1250, currency: "USD", accountable: Depository.new)
        AccountProvider.create!(account: account, provider: @item.brex_accounts.first)
      end
      if options[:second_linked]
        second = @item.brex_accounts.first.dup.tap { |brex_account| brex_account.update!(account_id: "card_acc_second", name: "Brex Card") }
        account = @item.family.accounts.create!(name: "Brex Card", balance: 300, currency: "USD", accountable: CreditCard.new)
        AccountProvider.create!(account: account, provider: second)
      end
      visible = { all: @item.accounts.to_a, linked: @item.accounts.order(:name).where(name: "Brex Operating").to_a, none: [] }.fetch(options[:visible])

      renderable = yield(visible)
      renderable.is_a?(Hash) ? ApplicationController.render(**renderable) : ApplicationController.render(renderable, layout: false)
    end
end

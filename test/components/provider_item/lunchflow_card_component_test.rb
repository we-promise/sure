# frozen_string_literal: true

require "test_helper"

class ProviderItem::LunchflowCardComponentTest < ActiveSupport::TestCase
  include ProviderItemSnapshots

  setup do
    travel_to Time.zone.parse("2026-11-15 12:00:00")
    @item = lunchflow_items(:one)
    @item.class.any_instance.stubs(:last_synced_at).returns(3.hours.ago)
  end

  CASES = {
    "lunchflow_card_admin" => { user: :family_admin, visible: :all },
    "lunchflow_card_admin_with_linked_account" => { user: :family_admin, visible: :all, linked: true },
    "lunchflow_card_member_with_accounts" => { user: :family_member, visible: :linked, linked: true },
    "lunchflow_card_member_shown_one_of_two" => { user: :family_member, visible: :linked, linked: true, second_linked: true },
    "lunchflow_card_member_without_accounts" => { user: :family_member, visible: :none },
    "lunchflow_card_scheduled_for_deletion" => { user: :family_admin, visible: :all, deleting: true },
    "lunchflow_card_sync_error" => { user: :family_admin, visible: :all, sync_error: "Token expired" }
  }.freeze

  CASES.each do |name, options|
    test "#{name}: the card partial renders as before" do
      assert_matches_provider_item_snapshot(name, render_card(options) { |visible| { partial: "lunchflow_items/lunchflow_item", locals: { lunchflow_item: @item, visible_accounts: visible } } })
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
        account = @item.family.accounts.create!(name: "Lunch Flow Everyday", balance: 1250, currency: "USD", accountable: Depository.new)
        AccountProvider.create!(account: account, provider: @item.lunchflow_accounts.first)
      end
      if options[:second_linked]
        second = @item.lunchflow_accounts.first.dup.tap { |lunchflow_account| lunchflow_account.update!(account_id: "lf_acc_second", name: "Lunch Flow Card") }
        account = @item.family.accounts.create!(name: "Lunch Flow Card", balance: 300, currency: "USD", accountable: CreditCard.new)
        AccountProvider.create!(account: account, provider: second)
      end
      visible = { all: @item.accounts.to_a, linked: @item.accounts.order(:name).where(name: "Lunch Flow Everyday").to_a, none: [] }.fetch(options[:visible])

      renderable = yield(visible)
      renderable.is_a?(Hash) ? ApplicationController.render(**renderable) : ApplicationController.render(renderable, layout: false)
    end
end

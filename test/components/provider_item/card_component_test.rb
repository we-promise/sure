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

  # The accounts page passes counts, institutions and sync stats precomputed per
  # connection. Values that differ from the model's own show which one the card read.
  test "the card reads the accounts page's precomputed counts over the model's" do
    stats = { "total_accounts" => 9, "linked_accounts" => 2, "unlinked_accounts" => 7 }
    model_unlinked = @item.unlinked_accounts_count
    assert_operator model_unlinked, :>, 0

    all_linked = render_card(user: :family_admin, visible: :all) do |visible|
      ProviderItem::CardComponent.new(
        item: @item, visible_accounts: visible,
        sync_stats_map: { @item.id => stats },
        account_counts_map: { @item.id => { linked: 3, unlinked: 0, total: 3 } },
        institutions_count_map: { @item.id => 5 }
      )
    end
    assert_not_includes all_linked, I18n.t("brex_items.brex_item.setup_needed")
    assert_includes all_linked, I18n.t("provider_sync_summary.accounts.total", count: 9)
    assert_includes all_linked, I18n.t("provider_sync_summary.accounts.institutions", count: 5)

    some_unlinked = render_card(user: :family_admin, visible: :all) do |visible|
      ProviderItem::CardComponent.new(
        item: @item, visible_accounts: visible,
        sync_stats_map: { @item.id => stats },
        account_counts_map: { @item.id => { linked: 2, unlinked: 5, total: 7 } },
        institutions_count_map: { @item.id => 5 }
      )
    end
    assert_includes some_unlinked, ERB::Util.html_escape(I18n.t("brex_items.brex_item.setup_description", linked: 2, total: 7))
  end

  test "snapshots treat a blank CSRF token as a difference" do
    assert_equal %(<input name="authenticity_token" value="">\n), normalise_provider_item_html(%(<input name="authenticity_token" value="">))
    assert_equal %(<input name="authenticity_token" value="CSRF">\n), normalise_provider_item_html(%(<input name="authenticity_token" value="abc123">))
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

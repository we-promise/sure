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

  # Snapshots normalise record ids, so they would accept a delete form aimed at
  # another connection; check the target before normalising.
  test "the card's delete form targets its own connection" do
    html = render_card(user: :family_admin, visible: :all) { |visible| ProviderItem::CardComponent.new(item: @item, visible_accounts: visible) }

    assert_includes html, %(action="/brex_items/#{@item.id}")
  end

  # #3630: a member shown one of a connection's two accounts must see only that one.
  test "the card lists only the accounts it is given" do
    html = render_card(user: :family_member, visible: :linked, linked: true, second_linked: true) do |visible|
      ProviderItem::CardComponent.new(item: @item, visible_accounts: visible)
    end

    assert_includes html, "Brex Operating"
    assert_not_includes html, "Brex Card"
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

  # Both setup prompts are one DS::EmptyState: the branch picks only the title
  # and description, and the action is the setup link.
  test "each setup prompt renders as a DS::EmptyState with the setup link" do
    prompts = {
      { linked: 2, unlinked: 5, total: 7 } => [
        I18n.t("brex_items.brex_item.setup_needed"),
        I18n.t("brex_items.brex_item.setup_description", linked: 2, total: 7)
      ],
      { linked: 0, unlinked: 0, total: 0 } => [
        I18n.t("brex_items.brex_item.no_accounts_title"),
        I18n.t("brex_items.brex_item.no_accounts_description")
      ]
    }

    prompts.each do |counts, (title, description)|
      html = render_card(user: :family_admin, visible: :all) do |visible|
        ProviderItem::CardComponent.new(item: @item, visible_accounts: visible, account_counts_map: { @item.id => counts })
      end
      page = Nokogiri::HTML5.fragment(html)

      empty_states = page.css("div.text-center.py-12")
      assert_equal 1, empty_states.size, "#{counts}: expected one DS::EmptyState"
      empty_state = empty_states.first
      assert_equal [ title, description ], empty_state.css("p").map { |p| p.text.strip }
      link = empty_state.at_css("a[href='/brex_items/#{@item.id}/setup_accounts']")
      assert link, "#{counts}: the setup link is the empty state's action"
      assert_includes link.text, I18n.t("brex_items.brex_item.setup_action")
      assert_empty page.css("div.p-4.gap-3.justify-center"), "#{counts}: the hand-built prompt is gone"
    end
  end

  # The last sync's stats, with an account count no fixture produces and a
  # skipped transaction that names an account.
  CONNECTION_STATS = {
    "total_accounts" => 7, "linked_accounts" => 1, "unlinked_accounts" => 6,
    "tx_seen" => 3, "tx_skipped" => 1, "skip_details" => [ { "name" => "Payroll run", "reason" => "excluded" } ]
  }.freeze

  # A viewer who cannot see every linked account, admin or not, gets no
  # connection-wide counts and no account names; only an admin gets the setup
  # prompt. This reverses #3630's "counts without the names" for a partly
  # shared member.
  test "a member who sees none of the connection's accounts gets no counts, names or setup prompt" do
    html = render_card_with_stats(user: :family_member, visible: :none)

    assert_equal({ setup: false, header_summary: false, counts: false, names: false }, connection_details(html))
    assert_not_includes html, ERB::Util.html_escape(I18n.t("brex_items.brex_item.setup_description", linked: 0, total: 1))
  end

  test "a member shown one of two linked accounts gets no counts or names" do
    html = render_card_with_stats(user: :family_member, visible: :linked, linked: true, second_linked: true)

    assert_equal({ setup: false, header_summary: false, counts: false, names: false }, connection_details(html))
  end

  test "a member who sees every linked account gets the counts and names but no setup prompt" do
    html = render_card_with_stats(user: :family_member, visible: :linked, linked: true, extra_unlinked: true)

    assert_equal({ setup: false, header_summary: true, counts: true, names: true }, connection_details(html))
  end

  test "a member gets no setup prompt for a connection without accounts" do
    html = render_card(user: :family_member, visible: :none) do |visible|
      ProviderItem::CardComponent.new(item: @item, visible_accounts: visible, account_counts_map: { @item.id => { linked: 0, unlinked: 0, total: 0 } })
    end

    assert_not_includes html, I18n.t("brex_items.brex_item.no_accounts_title")
    assert_not_includes html, "/brex_items/#{@item.id}/setup_accounts"
  end

  test "an admin shown one of two linked accounts gets no counts or names" do
    html = render_card_with_stats(user: :family_admin, visible: :linked, linked: true, second_linked: true)

    assert_equal({ setup: false, header_summary: false, counts: false, names: false }, connection_details(html))
    assert_not_includes html, ERB::Util.html_escape(@item.institution_summary)
  end

  test "an admin gets the counts, names and setup prompt" do
    html = render_card_with_stats(user: :family_admin, visible: :all)

    assert_equal({ setup: true, header_summary: true, counts: true, names: true }, connection_details(html))
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
      if options[:extra_unlinked]
        @item.brex_accounts.first.dup.tap { |brex_account| brex_account.update!(account_id: "unlinked_extra", name: "Brex Savings") }
      end
      visible = { all: @item.accounts.to_a, linked: @item.accounts.order(:name).where(name: "Brex Operating").to_a, none: [] }.fetch(options[:visible])

      renderable = yield(visible)
      renderable.is_a?(Hash) ? ApplicationController.render(**renderable) : ApplicationController.render(renderable, layout: false)
    end

    def render_card_with_stats(options)
      render_card(options) do |visible|
        ProviderItem::CardComponent.new(item: @item, visible_accounts: visible, sync_stats_map: { @item.id => CONNECTION_STATS })
      end
    end

    def connection_details(html)
      {
        setup: html.include?("/brex_items/#{@item.id}/setup_accounts"),
        header_summary: html.include?(ERB::Util.html_escape(@item.sync_status_summary)),
        counts: html.include?(I18n.t("provider_sync_summary.accounts.total", count: 7)),
        names: html.include?("Payroll run")
      }
    end
end

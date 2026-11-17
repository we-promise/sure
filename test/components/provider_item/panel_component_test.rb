# frozen_string_literal: true

require "test_helper"

class ProviderItem::PanelComponentTest < ActiveSupport::TestCase
  include ProviderItemSnapshots

  setup do
    travel_to Time.zone.parse("2026-11-15 12:00:00")
    @item = brex_items(:one)
    Current.stubs(:user).returns(users(:family_admin))
    Current.stubs(:family).returns(@item.family)
  end

  CASES = {
    "brex_panel_without_connections" => { items: :none },
    "brex_panel_with_connection" => { items: :one },
    "brex_panel_syncing_with_error" => { items: :one, syncing: true, error: "Token rejected" }
  }.freeze

  CASES.each do |name, options|
    test "#{name}: the panel partial renders as before" do
      assert_matches_provider_item_snapshot(name, render_panel(options))
    end
  end

  test "the Brex panel renders through ProviderItem::PanelComponent" do
    ProviderItem::PanelComponent.any_instance.expects(:before_render).once

    render_panel(items: :one)
  end

  test "the panel takes its turbo id from the provider's panel declaration" do
    declarations = Provider::Factory.panel_declarations.map do |panel|
      panel[:key] == "brex" ? panel.merge(turbo_id: "declared-brex") : panel
    end
    Provider::Factory.stubs(:panel_declarations).returns(declarations)

    assert_includes render_panel(items: :one), %(id="declared-brex-providers-panel")
  end

  private
    def render_panel(options)
      @item.class.any_instance.stubs(:syncing?).returns(true) if options[:syncing]
      items = options[:items] == :none ? @item.class.none : @item.class.where(id: @item.id)

      ApplicationController.render(partial: "settings/providers/brex_panel", locals: { brex_items: items, error_message: options[:error] })
    end
end

# frozen_string_literal: true

require "test_helper"

class ProviderItem::MercuryPanelComponentTest < ActiveSupport::TestCase
  include ProviderItemSnapshots

  setup do
    travel_to Time.zone.parse("2026-11-15 12:00:00")
    @item = mercury_items(:one)
    Current.stubs(:user).returns(users(:family_admin))
    Current.stubs(:family).returns(@item.family)
  end

  CASES = {
    "mercury_panel_without_connections" => { items: :none },
    "mercury_panel_with_connection" => { items: :one },
    "mercury_panel_syncing_with_error" => { items: :one, syncing: true, error: "Token rejected" }
  }.freeze

  CASES.each do |name, options|
    test "#{name}: the panel partial renders as before" do
      assert_matches_provider_item_snapshot(name, render_panel(options))
    end
  end

  test "the Mercury panel renders through ProviderItem::PanelComponent" do
    ProviderItem::PanelComponent.any_instance.expects(:before_render).once

    render_panel(items: :one)
  end

  private
    def render_panel(options)
      @item.class.any_instance.stubs(:syncing?).returns(true) if options[:syncing]
      items = options[:items] == :none ? @item.class.none : @item.class.where(id: @item.id)

      ApplicationController.render(partial: "settings/providers/mercury_panel", locals: { mercury_items: items, error_message: options[:error] })
    end
end

# frozen_string_literal: true

require "test_helper"

class ProviderItem::LunchflowPanelComponentTest < ActiveSupport::TestCase
  include ProviderItemSnapshots

  setup do
    travel_to Time.zone.parse("2026-11-15 12:00:00")
    @item = lunchflow_items(:one)
  end

  CASES = {
    "lunchflow_panel_without_connection" => { family: :empty, user: :empty },
    "lunchflow_panel_with_connection" => { family: :dylan_family, user: :family_admin },
    "lunchflow_panel_with_error" => { family: :dylan_family, user: :family_admin, error: "API key rejected" }
  }.freeze

  CASES.each do |name, options|
    test "#{name}: the panel partial renders as before" do
      assert_matches_provider_item_snapshot(name, render_panel(options))
    end
  end

  test "the Lunch Flow panel renders through ProviderItem::PanelComponent" do
    ProviderItem::PanelComponent.any_instance.expects(:before_render).once

    render_panel(CASES.fetch("lunchflow_panel_with_connection"))
  end

  private
    def render_panel(options)
      Current.stubs(:user).returns(users(options[:user]))
      Current.stubs(:family).returns(families(options[:family]))
      @item.update_columns(base_url: "https://lunchflow.example/api/v1", sync_start_date: Time.zone.parse("2026-01-15 00:00:00"))

      ApplicationController.render(partial: "settings/providers/lunchflow_panel", locals: { error_message: options[:error] })
    end
end

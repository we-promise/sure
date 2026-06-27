class BasisController < ApplicationController
  before_action :require_preview_features!

  RANGES = {
    "30d" => 30,
    "90d" => 90,
    "1y" => 365
  }.freeze

  def show
    @range = RANGES.key?(params[:range]) ? params[:range] : "all"
    start_date = RANGES[@range] ? RANGES[@range].days.ago.to_date : nil
    live_snapshot_result = BasisTrade::LiveSnapshotBuilder.new(family: Current.family).call

    @basis_chart_payload = BasisTradeSeriesBuilder.new(
      family: Current.family,
      start_date: start_date
    ).payload

    @has_snapshots = @basis_chart_payload[:points].any?
    @basis_live_snapshot = live_snapshot_result.snapshot
    @basis_live_error = live_snapshot_result.error
    @basis_sources_configured = live_snapshot_result.configured

    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ],
                     [ t("basis.show.title"), nil ] ]
  end
end

namespace :basis do
  # Minimal manual ingest path so the Basis page can be populated without
  # hand-editing the database. Values are passed in major currency units and
  # converted to the integer subunits the snapshot stores.
  #
  # Example:
  #   FAMILY_EMAIL=user@example.com \
  #   RECORDED_AT="2026-06-20 12:00:00" \
  #   SPOT=15000 SHORT=-250 FUNDING=120 REWARDS=40 \
  #   bin/rails basis:record_snapshot
  desc "Record a single basis trade snapshot for a family"
  task record_snapshot: :environment do
    family =
      if ENV["FAMILY_ID"].present?
        Family.find(ENV["FAMILY_ID"])
      elsif ENV["FAMILY_EMAIL"].present?
        User.find_by!(email: ENV["FAMILY_EMAIL"]).family
      else
        abort "Provide FAMILY_ID or FAMILY_EMAIL"
      end

    recorded_at = ENV["RECORDED_AT"].present? ? Time.zone.parse(ENV["RECORDED_AT"]) : Time.current
    factor = BasisTradeSeriesBuilder::CENTS_PER_UNIT

    snapshot = family.basis_trade_snapshots.find_or_initialize_by(recorded_at: recorded_at)
    snapshot.assign_attributes(
      spot_leg_cents: (ENV.fetch("SPOT", 0).to_f * factor).round,
      short_leg_cents: (ENV.fetch("SHORT", 0).to_f * factor).round,
      funding_accrued_cents: (ENV.fetch("FUNDING", 0).to_f * factor).round,
      rewards_accrued_cents: (ENV.fetch("REWARDS", 0).to_f * factor).round,
      currency: ENV["CURRENCY"].presence || family.primary_currency_code
    )
    snapshot.save!

    puts "Recorded basis snapshot #{snapshot.id} for #{family.name} at #{recorded_at}"
  end
end

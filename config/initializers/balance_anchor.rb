# Linked-account current balance anchor runtime configuration
Rails.application.configure do
  # Controls whether a stale `current_anchor` is carried forward when the transactions
  # imported in the same sync already explain the move to the newly reported balance.
  # When false, every stale anchor is frozen as a reconciliation waypoint ("Manual
  # balance update"), which is the historical behaviour.
  # Default: false
  config.x.balance.reuse_explained_anchor = ENV["BALANCE_REUSE_EXPLAINED_ANCHOR"].to_s.strip.downcase.in?(%w[1 true yes])
end

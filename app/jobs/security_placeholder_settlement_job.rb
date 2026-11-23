# Merges a blank-MIC "resolution_pending" placeholder into the listed security
# a later search found for its ticker. It runs after the resolving transaction
# commits, so records an import built in memory against the placeholder are
# already saved when their security row goes away.
class SecurityPlaceholderSettlementJob < ApplicationJob
  def perform(placeholder_id, security_id)
    placeholder = Security.find_by(id: placeholder_id)
    security = Security.find_by(id: security_id)
    return unless placeholder && security

    Security::Merger.new(from: placeholder, into: security).merge!(
      condition: ->(source) { source.exchange_operating_mic.blank? && source.offline? && source.offline_reason == "resolution_pending" }
    )
  end
end

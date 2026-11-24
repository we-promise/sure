# Gives a family's provider merchants that have a website the logo generated from it. Queued by
# the Enhance button next to its AI run, which never touches logos, so a click refreshes them even
# when the run fails. Each family sync does the same (Family::Syncer#perform_post_sync).
class MerchantLogoBackfillJob < ApplicationJob
  queue_as :default

  def perform(family) = family.backfill_provider_merchant_logos
end

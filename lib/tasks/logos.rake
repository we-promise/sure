# frozen_string_literal: true

namespace :logos do
  desc "Detach account logos whose blob file is missing from the storage service. " \
       "A detached logo falls back to the auto chain (Brandfetch -> provider logo -> favicon -> default icon) " \
       "until a new valid logo is uploaded."
  task repair_missing: :environment do
    repaired = 0
    checked = 0

    Account.joins(:logo_attachment).includes(:logo_attachment).find_each do |account|
      blob = account.logo.blob
      next if blob.nil?

      checked += 1

      # One existence probe per attached logo. Only run when repairing; per
      # -request probes would add synchronous storage calls to page renders.
      next if blob.service.exist?(blob.key)

      puts "Detaching missing logo blob #{blob.key} from account #{account.id} (#{account.name})"
      account.logo.detach
      repaired += 1
    end

    puts "Checked #{checked} attached account logo(s); detached #{repaired} with missing storage file(s)."
  end
end

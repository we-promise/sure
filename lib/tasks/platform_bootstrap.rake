# frozen_string_literal: true

require "io/console"

namespace :platform_bootstrap do
  desc "Create Risingstone/Mahetel company workspaces and platform owner super admins"
  task multi_company_owners: :environment do
    dry_run = ENV["DRY_RUN"] == "true"

    passwords = {
      "adminF0@bookeepz.net" => secret_value("ADMIN_F0_PASSWORD", "Password for adminF0@bookeepz.net"),
      "adminF1@bookeepz.net" => secret_value("ADMIN_F1_PASSWORD", "Password for adminF1@bookeepz.net")
    }

    result = PlatformBootstrap::MultiCompanyOwners.new(passwords: passwords, dry_run: dry_run).call

    puts "Multi-company owner bootstrap #{dry_run ? 'validated in dry-run mode' : 'completed'}."
    puts "Families:"
    result.families.each do |family|
      puts "  - #{family.name}"
    end

    puts "Users:"
    result.users.each do |user|
      puts "  - #{user.email}: #{user.role}, primary_family=#{user.family.name}"
    end
  end

  def secret_value(env_key, prompt)
    return ENV.fetch(env_key) if ENV.key?(env_key)

    unless $stdin.tty?
      raise ArgumentError, "Set #{env_key} or run this task from an interactive TTY"
    end

    print "#{prompt}: "
    value = $stdin.noecho(&:gets).to_s.chomp
    puts
    value
  end
end

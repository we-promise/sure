# frozen_string_literal: true

require "io/console"

namespace :platform_bootstrap do
  desc "Create Risingstone/Mahetel company workspaces and platform owner super admins"
  task multi_company_owners: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV["DRY_RUN"])

    passwords = PlatformBootstrap::MultiCompanyOwners::OWNERS.to_h do |owner|
      email = owner.fetch(:email)
      [ email, secret_value(env_key_for(owner), "Password for #{email}") ]
    end

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

    $stderr.print "#{prompt}: "
    value = $stdin.noecho(&:gets).to_s.chomp
    $stderr.puts
    value
  end

  def env_key_for(owner)
    case owner.fetch(:email)
    when "adminF0@bookeepz.net"
      "ADMIN_F0_PASSWORD"
    when "adminF1@bookeepz.net"
      "ADMIN_F1_PASSWORD"
    else
      raise ArgumentError, "No password environment variable configured for #{owner.fetch(:email)}"
    end
  end
end

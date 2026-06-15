# frozen_string_literal: true

require "io/console"

namespace :platform_bootstrap do
  desc "Provision Risingstone/Mahetel workspaces with platform super admins and family admins"
  task multi_company_owners: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV["DRY_RUN"])

    passwords = (
      PlatformBootstrap::MultiCompanyOwners::OWNERS +
      PlatformBootstrap::MultiCompanyOwners::FAMILY_ADMINS
    ).to_h do |owner|
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
    if ENV.key?(env_key)
      value = ENV.fetch(env_key)
      if value.strip.empty?
        message = "Set #{env_key} to a non-empty value or unset it to use an interactive prompt"
        raise ArgumentError, message
      end

      return value
    end

    unless $stdin.tty?
      raise ArgumentError, "Set #{env_key} or run this task from an interactive TTY"
    end

    $stderr.print "#{prompt}: "
    value = $stdin.noecho(&:gets).to_s.chomp
    $stderr.puts
    value
  end

  def env_key_for(owner)
    return owner.fetch(:password_env_key) if owner.key?(:password_env_key)

    email = owner.fetch(:email)
    match = email.match(/\Aadmin(F\d+)@bookeepz\.net\z/i)
    raise ArgumentError, "No password environment variable configured for #{email}" unless match

    "ADMIN_#{match[1].upcase}_PASSWORD"
  end
end

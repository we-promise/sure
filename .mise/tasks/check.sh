#!/usr/bin/env bash
#MISE description="Check dependencies, native libraries, database access, worker, and HTTP readiness"
set -euo pipefail
cd "$MISE_PROJECT_ROOT"
bundle check
bin/rails runner 'require "vips"; require "sidekiq/api"; ActiveRecord::Base.connection.execute("SELECT 1"); abort "No Sidekiq worker" if Sidekiq::ProcessSet.new.size.zero?; puts "Database, Sidekiq and libvips #{Vips.version_string} ready"'
ruby -rnet/http -e '
  base = "http://127.0.0.1:#{ENV.fetch("PORT", "3000")}"
  [ "/up", "/registration/new" ].each do |path|
    uri = URI(base + path)
    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 10) { |http| http.get(uri.request_uri) }
    abort "#{path}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    if path == "/registration/new"
      %w[email password].each do |field|
        abort "Registration form missing #{field}" unless response.body.include?(%(name="user[#{field}]"))
      end
    end
  end
  puts "Health and registration responses verified"
'

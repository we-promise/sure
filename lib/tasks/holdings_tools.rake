# frozen_string_literal: true

# Utilities for demonstrating holdings UI features (e.g., Day Change)
#
# Seed a prior snapshot for an existing holding to visualize Day Change immediately.
# Example:
#   # Preview (no write):
#   # bin/rails 'sure:holdings:seed_prev_snapshot[holding_id=HOLDING_UUID,change_pct=2,days_ago=1,dry_run=true]'
#   # Apply (writes):
#   # bin/rails 'sure:holdings:seed_prev_snapshot[holding_id=HOLDING_UUID,change_pct=2,days_ago=1,dry_run=false]'
#
# Remove a previously seeded snapshot by id:
#   # bin/rails 'sure:holdings:remove_snapshot[id=HOLDING_UUID]'

namespace :sure do
  namespace :holdings do
    desc "Seed a previous snapshot for Day Change demo. Args: holding_id, change_pct=2, days_ago=1, dry_run=true"
    task :seed_prev_snapshot, [ :holding_id, :change_pct, :days_ago, :dry_run ] => :environment do |_, args|
      kv = {}
      [ args[:holding_id], args[:change_pct], args[:days_ago], args[:dry_run] ].each do |raw|
        next unless raw.is_a?(String) && raw.include?("=")
        k, v = raw.split("=", 2)
        kv[k.to_s] = v
      end

      holding_id = (kv["holding_id"] || args[:holding_id]).presence
      change_pct = ((kv["change_pct"] || args[:change_pct] || 2).to_f) / 100.0
      days_ago   = (kv["days_ago"] || args[:days_ago] || 1).to_i
      raw_dry    = kv.key?("dry_run") ? kv["dry_run"] : args[:dry_run]
      dry_raw    = raw_dry.to_s.downcase
      # Default to dry_run=true unless explicitly disabled, and validate input strictly
      if raw_dry.nil? || dry_raw.blank?
        dry_run = true
      elsif %w[1 true yes y].include?(dry_raw)
        dry_run = true
      elsif %w[0 false no n].include?(dry_raw)
        dry_run = false
      else
        puts({ ok: false, error: "invalid_argument", message: "dry_run must be one of: true/yes/1 or false/no/0" }.to_json)
        exit 1
      end

      unless holding_id
        puts({ ok: false, error: "usage", message: "Provide holding_id" }.to_json)
        exit 1
      end

      h = Holding.find(holding_id)
      prev = h.dup
      prev.date = h.date - days_ago
      # Apply percentage change to price and amount (positive change_pct decreases values, negative increases)
      factor = (1.0 - change_pct)
      prev.price  = (h.price  * factor).round(4)
      prev.amount = (h.amount * factor).round(4)
      prev.external_id = nil

      if dry_run
        puts({ ok: true, dry_run: true, holding_id: h.id, would_create: prev.attributes.slice("account_id", "security_id", "date", "qty", "price", "amount", "currency") }.to_json)
      else
        prev.save!
        puts({ ok: true, created_prev_id: prev.id, date: prev.date, amount: prev.amount, price: prev.price }.to_json)
      end
    rescue => e
      puts({ ok: false, error: e.class.name, message: e.message }.to_json)
      exit 1
    end

    desc "Remove a seeded snapshot by its id. Args: snapshot_id"
    task :remove_snapshot, [ :snapshot_id ] => :environment do |_, args|
      id = args[:snapshot_id]
      unless id
        puts({ ok: false, error: "usage", message: "Provide id" }.to_json)
        exit 1
      end
      h = Holding.find(id)
      h.destroy!
      puts({ ok: true, removed: id }.to_json)
    rescue => e
      puts({ ok: false, error: e.class.name, message: e.message }.to_json)
      exit 1
    end
  end
end

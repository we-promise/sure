# frozen_string_literal: true

namespace :sure do
  namespace :simplefin do
    desc "Unlink all provider links for a SimpleFin item so its accounts move to 'Other accounts'. Args: item_id, dry_run=true"
    task :unlink_item, [ :item_id, :dry_run ] => :environment do |_, args|
      require "json"

      item_id = args[:item_id].to_s.strip.presence
      dry_raw  = args[:dry_run].to_s.downcase

      # Default to non-destructive (dry run) unless explicitly disabled
      dry_run = dry_raw.blank? ? true : %w[1 true yes y].include?(dry_raw)

      unless item_id.present?
        puts({ ok: false, error: "usage", example: "bin/rails 'sure:simplefin:unlink_item[ITEM_UUID,true]'" }.to_json)
        exit 1
      end

      # Basic UUID v4 validation (hyphenated 36 chars)
      uuid_v4 = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
      unless item_id.match?(uuid_v4)
        puts({ ok: false, error: "invalid_argument", message: "item_id must be a hyphenated UUID (v4)" }.to_json)
        exit 1
      end

      item = SimplefinItem.find(item_id)
      results = SimplefinItem::Unlinker.new(item, dry_run: dry_run).unlink_all!

      # Redact potentially sensitive names or identifiers in output
      safe_details = Array(results).map do |r|
        r.is_a?(Hash) ? r.except(:name, :payee, :account_number) : r
      end

      puts({ ok: true, dry_run: dry_run, item_id: item.id, unlinked_count: safe_details.size, details: safe_details }.to_json)
    rescue ActiveRecord::RecordNotFound
      puts({ ok: false, error: "not_found", message: "SimplefinItem not found for given item_id" }.to_json)
      exit 1
    rescue => e
      puts({ ok: false, error: e.class.name, message: e.message }.to_json)
      exit 1
    end
  end
end

# frozen_string_literal: true

namespace :sure do
  namespace :simplefin do
    desc "Unlink all provider links for a SimpleFin item so its accounts move to 'Other accounts'. Args: item_id, dry_run=true"
    task :unlink_item, [ :item_id, :dry_run ] => :environment do |_, args|
      require "json"

      item_id = args[:item_id].to_s.strip.presence
      dry_raw  = args[:dry_run].to_s.downcase

      # Default to non-destructive (dry run) unless explicitly disabled
      # Accept only explicit true/false values; abort on invalid input to prevent accidental destructive runs
      if dry_raw.blank?
        dry_run = true
      elsif %w[1 true yes y].include?(dry_raw)
        dry_run = true
      elsif %w[0 false no n].include?(dry_raw)
        dry_run = false
      else
        puts({ ok: false, error: "invalid_argument", message: "dry_run must be one of: true/yes/1 or false/no/0" }.to_json)
        exit 1
      end

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
      results = item.unlink_all!(dry_run: dry_run)

      # Redact potentially sensitive names or identifiers in output
      # Recursively redact sensitive fields from output
      def redact_sensitive(obj)
        case obj
        when Hash
          obj.except(:name, :payee, :account_number).transform_values { |v| redact_sensitive(v) }
        when Array
          obj.map { |item| redact_sensitive(item) }
        else
          obj
        end
    end

      safe_details = redact_sensitive(Array(results))

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

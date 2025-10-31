# frozen_string_literal: true

namespace :sure do
  namespace :simplefin do
    desc "Unlink all provider links for a SimpleFin item so its accounts move to 'Other accounts'. Args: item_id, dry_run=true"
    task :unlink_item, [:item_id, :dry_run] => :environment do |_, args|
      kv = {}
      [args[:item_id], args[:dry_run]].each do |raw|
        next unless raw.is_a?(String) && raw.include?("=")
        k, v = raw.split("=", 2)
        kv[k.to_s] = v
      end

      item_id = (kv["item_id"] || args[:item_id]).presence
      dry_raw = (kv["dry_run"] || args[:dry_run]).to_s.downcase
      dry_run = %w[1 true yes y].include?(dry_raw)

      unless item_id.present?
        puts({ ok: false, error: "usage", example: "bin/rails 'sure:simplefin:unlink_item[item_id=ITEM_UUID,dry_run=true]'" }.to_json)
        exit 1
      end

      item = SimplefinItem.find(item_id)
      results = SimplefinItem::Unlinker.new(item, dry_run: dry_run).unlink_all!

      puts({ ok: true, dry_run: dry_run, item_id: item.id, unlinked_count: results.size, details: results }.to_json)
    rescue => e
      puts({ ok: false, error: e.class.name, message: e.message }.to_json)
      exit 1
    end
  end
end

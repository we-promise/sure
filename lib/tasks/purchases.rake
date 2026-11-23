namespace :purchases do
  desc "Create purchases for receipt scans processed before purchases existed"
  task backfill_receipts: :environment do
    created = skipped = 0

    ReceiptScan.where(status: %w[completed needs_review]).where.missing(:purchase).find_each do |scan|
      receipt = scan.linked_transaction&.extra&.dig("receipt")
      # Only a receipt that was read: a scan the AI never got to carries just a status.
      if receipt.blank? || receipt.values_at("total", "merchant", "line_items").all?(&:blank?)
        skipped += 1
        next
      end

      if Purchase::FromReceiptScan.sync!(scan, extraction_hash: receipt, ai_metadata: { "backfilled" => true, "raw_output" => receipt })
        created += 1
      else
        skipped += 1
      end
    end

    puts "created=#{created} skipped=#{skipped}"
  end

  desc "Re-check stored order reads against the current total rules and clear outdated mismatch flags (no AI calls)"
  task revalidate: :environment do
    cleared = Purchase.email.where("review_reasons @> ?", [ { reason: "items_mismatch" } ].to_json)
      .find_each.count(&:revalidate_items_total!)

    puts "cleared=#{cleared}"
  end

  desc "Read the shop's domain from stored order emails, for shop logos (no AI calls)"
  task backfill_domains: :environment do
    updated = Purchase.email.where(merchant_domain: nil).find_each.count(&:backfill_merchant_domain!)

    puts "updated=#{updated}"
  end
end

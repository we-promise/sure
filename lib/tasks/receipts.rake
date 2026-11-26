namespace :receipts do
  desc "Measure receipt extraction on a private folder of receipts (NAME.jpg + NAME.json). FAMILY_ID=... [USER_ID=...] bin/rails receipts:evaluate[tmp/receipt_eval]"
  task :evaluate, [ :dir ] => :environment do |_task, args|
    family = Family.find(ENV.fetch("FAMILY_ID"))
    # Read under one member's AI switch, as their upload would be: USER_ID, or the first member with AI on.
    user = ENV["USER_ID"] ? family.users.find(ENV["USER_ID"]) : family.users.find_by!(ai_enabled: true)
    report = ReceiptScan::Evaluation.new(dir: args[:dir] || Rails.root.join("tmp/receipt_eval"), family:, user:).run

    puts "Receipts: #{report["count"]}"
    report["accuracy"].each { |field, value| puts format("  %-9s %5.1f%%", field, value * 100) }
    puts format("Flagged for review: %.1f%%", report["flag_rate"] * 100)
    puts "Mean latency: #{report["mean_latency_seconds"]}s"
  end
end

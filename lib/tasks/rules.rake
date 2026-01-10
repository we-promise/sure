namespace :rules do
  desc "Apply all rules for a family"
  task :apply_all, [ :family_id ] => :environment do |_t, args|
    family_id = args[:family_id]

    if family_id.blank?
      puts "Usage: bin/rails rules:apply_all[family_id]"
      exit 1
    end

    family = Family.find(family_id)
    rules = family.rules

    if rules.empty?
      puts "No rules found for family #{family_id}"
      exit 0
    end

    puts "Applying #{rules.count} rules for family #{family_id}..."

    rules.find_each do |rule|
      print "  Applying rule '#{rule.name || rule.id}'... "
      begin
        RuleJob.perform_now(rule, ignore_attribute_locks: true, execution_type: "manual")
        puts "done"
      rescue => e
        puts "failed: #{e.message}"
      end
    end

    puts "Finished applying all rules"
  end
end

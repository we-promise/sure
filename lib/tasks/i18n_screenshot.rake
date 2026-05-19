namespace :i18n_screenshot do
  desc "Seed dev DB with a ca-locale user + sample data for Playwright i18n shots"
  task seed: :environment do
    email = ENV.fetch("SHOT_EMAIL", "user@example.com")
    user = User.find_by(email: email)
    unless user
      puts "No #{email} found — run `bin/rails demo_data:default` first."
      exit 1
    end

    user.update!(locale: "ca", otp_required: false)
    user.update!(role: "super_admin") if User.column_names.include?("role") && user.respond_to?(:role=)
    puts "✅ User #{email} → locale=ca, otp_required=false, role=super_admin"

    family = user.family
    family.update!(locale: "ca") if family.respond_to?(:locale=) && family.respond_to?(:locale)
    puts "👨‍👩‍👧 Family: #{family.name}"

    puts ""
    puts "Login: #{email} / Password1!"
  end
end

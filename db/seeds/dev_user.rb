# Create a simple dev user for local testing
# Credentials: test@test.com / test

family = Family.find_or_create_by!(name: "Test Family") do |f|
  f.currency = "USD"
  f.locale = "en"
  f.country = "US"
  f.timezone = "America/New_York"
  f.date_format = "%m-%d-%Y"
end

user = User.find_or_initialize_by(email: "test@test.com")
user.assign_attributes(
  family: family,
  first_name: "Test",
  last_name: "User",
  role: "admin",
  password: "test",
  onboarded_at: Time.current,
  ai_enabled: true
)
user.save!

puts "Created dev user: test@test.com / test"

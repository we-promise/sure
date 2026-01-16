# Create a simple dev user for local testing
# Credentials: user@example.com / password

family = Family.find_or_create_by!(name: "Test Family") do |f|
  f.currency = "USD"
  f.locale = "en"
  f.country = "US"
  f.timezone = "America/New_York"
  f.date_format = "%m-%d-%Y"
end

user = User.find_or_initialize_by(email: "user@example.com")
user.assign_attributes(
  family: family,
  first_name: "Test",
  last_name: "User",
  role: "admin",
  password: "password",
  onboarded_at: Time.current,
  ai_enabled: true
)
user.save!

puts "Created dev user: user@example.com / password"

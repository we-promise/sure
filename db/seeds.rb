# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

if Rails.env.development?
  puts 'Run one of the following commands to create demo data: `rake demo_data:default` or `rake demo_data:kenya`'
end

Dir[Rails.root.join('db', 'seeds', '*.rb')].sort.each do |file|
  puts "Loading seed file: #{File.basename(file)}"
  require file
end

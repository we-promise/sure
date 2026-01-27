schedule_file = Rails.root.join("config/schedule.yml")

demo_schedule = {
  "reset_demo_data" => {
    "cron" => ENV.fetch("DEMO_DATA_RESET_CRON", "0 4 * * *"),
    "class" => "DemoDataResetJob",
    "queue" => "scheduled",
    "description" => "Resets demo data on demo installations"
  }
}.freeze

Sidekiq.configure_server do
  next unless schedule_file.exist?

  schedule = YAML.load_file(schedule_file)
  schedule["reset_demo_data"] = demo_schedule.fetch("reset_demo_data") if Demo::Mode.demo_mode?

  Sidekiq::Cron::Job.load_from_hash(schedule)
end

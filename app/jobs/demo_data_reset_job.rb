class DemoDataResetJob < ApplicationJob
  queue_as :scheduled

  def perform
    Demo::Generator.new.generate_default_data!
  end
end

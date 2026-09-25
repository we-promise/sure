# frozen_string_literal: true

class CodexLoginJob < ApplicationJob
  queue_as :high_priority

  def perform(login_id)
    Provider::Codex.perform_device_login(login_id)
  end
end

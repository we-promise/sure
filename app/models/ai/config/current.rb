# Holds the AI configuration snapshot for one request or job, rebuilt when one of its inputs
# changes, so a value saved in the UI applies at once.
class Ai::Config::Current < ActiveSupport::CurrentAttributes
  attribute :config, :fingerprint
end

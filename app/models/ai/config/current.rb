# Holds the AI configuration snapshot for one request or job, rebuilt when one of its inputs
# changes, so a value saved in the UI applies at once, as today. PR 7 replaces this with a
# per-process cache and a version stamp (section 4.6).
class Ai::Config::Current < ActiveSupport::CurrentAttributes
  attribute :config, :fingerprint
end

# frozen_string_literal: true

begin
  require "rswag/specs"
rescue LoadError
  # rswag is not available in this environment (likely production where
  # rswag is in the test/development group). Skip loading rswag rake
  # tasks so `rake -P` can run during asset precompilation / deploy.
end

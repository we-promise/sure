release: rails db:migrate
web: bundle exec puma -C config/puma.rb
worker: bundle exec sidekiq -c 3
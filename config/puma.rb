workers ENV.fetch('WEB_CONCURRENCY', 2).to_i
threads_count = ENV.fetch('RAILS_MAX_THREADS', 4).to_i
threads threads_count, threads_count
port ENV.fetch('PORT', 4567)
environment ENV.fetch('RACK_ENV', 'production')
preload_app!

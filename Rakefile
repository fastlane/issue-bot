require_relative 'bot'

task :run do
  # This is run frequently, so we want to avoid processing and notifying
  # about untouched PRs this often
  Fastlane::Bot.new.start(process_prs: false)
end

task :process_all do
  # This is run infrequently, so we want process and notify about untouched PRs
  # to keep us aware of them
  Fastlane::Bot.new.start(process_prs: true)
end

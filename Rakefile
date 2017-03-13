require_relative 'bot'

task :process_issues do
  Fastlane::Bot.new.start(process: :issues)
end

task :process_prs do
  Fastlane::Bot.new.start(process: :prs)
end

task :post_unreleased_changes do
  require 'open-uri'
  require 'json'
  require 'excon'

  url = "https://rubygems.org/api/v1/gems/fastlane.json"
  rubygems_data = JSON.parse(open(url).read)
  live_version = rubygems_data["version"]
  
  number_of_commits = 0
  published_date = nil
  commits = JSON.parse(open("https://api.github.com/repos/fastlane/fastlane/commits").read)
  commits.each do |current|
    if current["commit"]["message"].start_with?("Version bump")
      published_date = Time.parse(current["commit"]["author"]["date"])
      break
    end
    number_of_commits += 1
  end

  number_of_days = ((Time.now - published_date) / 60.0 / 60.0 / 24.0).round
  exit if number_of_commits == 0

  diff_url = "https://github.com/fastlane/fastlane/compare/#{live_version}...master"
  puts "Posting to slack that #{number_of_commits} commits are pending for release since #{number_of_days} days"
  days_str = number_of_days > 4 ? "*#{number_of_days} days*" : "#{number_of_days} days" # bold if more than 4 days
  post_body = {
    text: ":ship: Last release was #{days_str} ago, with <#{diff_url}|#{number_of_commits} commits> pending for release"
  }.to_json

  response = Excon.post(ENV['ACTION_CHANNEL_SLACK_WEB_HOOK_URL'], body: post_body, headers: { "Content-Type" => "application/json" })

  if response.status == 200
    puts "Successfully notified the Slack room about PRs that need attention"
  else
    puts "Failed to notify the Slack room about PRs that need attention"
  end
end

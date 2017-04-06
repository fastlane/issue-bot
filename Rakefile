require_relative 'bot'
require 'logger'

task :process_issues do
  logger = Logger.new(logger_path('process_issues.log'))
  begin
    Fastlane::Bot.new(logger).start(process: :issues)
  rescue => ex
    logger.fatal(ex.to_s)
    logger.fatal(ex.backtrace.join("\n"))
    raise ex
  end
end

task :process_prs do
  logger = Logger.new(logger_path('process_prs.log'))
  begin
    Fastlane::Bot.new(logger).start(process: :prs)
  rescue => ex
    logger.fatal(ex.to_s)
    logger.fatal(ex.backtrace.join("\n"))
    raise ex
  end
end

task :post_unreleased_changes do
  require 'open-uri'
  require 'json'
  require 'excon'

  logger = Logger.new(logger_path('post_unreleased_changes.log'))
  begin
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
    logger.info("Posting to slack that #{number_of_commits} commits are pending for release since #{number_of_days} days")
    days_str = number_of_days > 4 ? "*#{number_of_days} days*" : "#{number_of_days} days" # bold if more than 4 days
    post_body = {
      text: ":ship: Last release was #{days_str} ago, with <#{diff_url}|#{number_of_commits} commits> pending for release"
    }.to_json

    response = Excon.post(ENV['ACTION_CHANNEL_SLACK_WEB_HOOK_URL'], body: post_body, headers: { "Content-Type" => "application/json" })

    if response.status == 200
      logger.info("Successfully notified the Slack room about PRs that need attention")
    else
      logger.info("Failed to notify the Slack room about PRs that need attention")
    end
  rescue => ex
    logger.fatal(ex.to_s)
    logger.fatal(ex.backtrace.join("\n"))
    raise ex
  end
end

def logger_path(name)
  ENV['FASTLANE_ISSUE_BOT_LOG_PATH'] ? File.join(ENV['FASTLANE_ISSUE_BOT_LOG_PATH'], name) : STDOUT
end
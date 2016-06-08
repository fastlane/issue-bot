require 'octokit'
require 'pry'
require 'excon'
require 'colored'
require 'json'

module Fastlane
  class Bot
    SLUG = "fastlane/issue-bot"
    ISSUE_WARNING = 2
    ISSUE_CLOSED = 0.3 # plus the x months from ISSUE_WARNING
    AWAITING_REPLY = "awaiting-reply"

    def client
      @client ||= Octokit::Client.new(access_token: ENV["GITHUB_API_TOKEN"])
    end

    def start
      client.auto_paginate = true
      puts "Fetching issues from '#{SLUG}'..."
      
      counter = 0
      client.issues(SLUG, per_page: 1000, state: "open").each do |issue|
        next unless issue.pull_request.nil? # no PRs for now
        return if issue.comments == 0 # we haven't replied yet :(
        puts "Investigating issue ##{issue.number}..."
        process(issue)
        smart_sleep
        counter += 1
      end
      puts "[SUCCESS] I worked through #{counter} issues / PRs, much faster than human beings, bots will take over"
    end

    def process(issue)
      diff_in_months = (Time.now - issue.updated_at) / 60.0 / 60.0 / 24.0 / 30.0

      warning_sent = !!issue.labels.find { |a| a.name == AWAITING_REPLY }

      if warning_sent && diff_in_months > ISSUE_CLOSED
        puts "Issue #{issue.number} (#{issue.title}) is #{diff_in_months} months old, closing now"
        body = ["There hasn't been any activity on this issue the last 3 months"]
        body << "This issue will be closed for now. Please feel free to [re-open a new one](https://github.com/fastlane/issue-bot/issues/new) :+1:"
        client.add_comment(SLUG, issue.number, body.join("\n\n"))
        client.close_issue(SLUG, issue.number)
        client.add_labels_to_an_issue(SLUG, issue.number, ['auto-closed'])
      elsif diff_in_months > ISSUE_WARNING
        return if issue.labels.find { |a| a.name == AWAITING_REPLY }

        puts "Issue #{issue.number} (#{issue.title}) is #{diff_in_months} months old, pinging now"
        body = ["There hasn't been any activity on this issue the last 2 months"]
        body << "Due to the high number of incoming issues we have to clean some of the old ones, as many of the issues have been resolved with the most recent updats."
        body << "If this issue is still relevant to you, please let us know by commenting with the most up to date information :+1:"
        
        client.add_comment(SLUG, issue.number, body.join("\n\n"))
        client.add_labels_to_an_issue(SLUG, issue.number, [AWAITING_REPLY])
      end
    end

    def smart_sleep
      sleep 1
    end
  end
end

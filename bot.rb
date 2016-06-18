require 'octokit'
require 'pry'
require 'excon'
require 'colored'
require 'json'

module Fastlane
  class Bot
    SLUG = "fastlane/fastlane"
    ISSUE_WARNING = 2
    ISSUE_CLOSED = 0.3 # plus the x months from ISSUE_WARNING
    AWAITING_REPLY = "waiting-for-reply"
    AUTO_CLOSED = "auto-closed"

    def client
      @client ||= Octokit::Client.new(access_token: ENV["GITHUB_API_TOKEN"])
    end

    def start
      client.auto_paginate = true
      puts "Fetching issues from '#{SLUG}'..."
      
      counter = 0
      client.issues(SLUG, per_page: 30, state: "open", direction: 'asc').each do |issue|
        next unless issue.pull_request.nil? # no PRs for now
        next if issue.comments == 0 # we haven't replied yet :(
        next if issue.labels.collect { |a| a.name }.include?("feature") # we ignore all feature requests for now

        puts "Investigating issue ##{issue.number}..."
        process(issue)
        counter += 1
      end
      puts "[SUCCESS] I worked through #{counter} issues / PRs, much faster than human beings, bots will take over"
    end

    def process(issue)
      diff_in_months = (Time.now - issue.updated_at) / 60.0 / 60.0 / 24.0 / 30.0

      warning_sent = !!issue.labels.find { |a| a.name == AWAITING_REPLY }
      if warning_sent && diff_in_months > ISSUE_CLOSED
        # We sent off a warning, but we have to check if the user replied
        if client.issue_comments(SLUG, issue.number).last.user.login == client.user.login
          # No reply from the user, let's close the issue
          puts "https://github.com/#{SLUG}/issues/#{issue.number} (#{issue.title}) is #{diff_in_months.round(1)} months old, closing now"
          body = []
          body << "This issue will be auto-closed because there hasn't been any activity for a few months. Feel free to [open a new one](https://github.com/fastlane/fastlane/issues/new) if you still experience this problem 👍"
          client.add_comment(SLUG, issue.number, body.join("\n\n"))
          client.close_issue(SLUG, issue.number)
          client.add_labels_to_an_issue(SLUG, issue.number, AUTO_CLOSED)
        else
          # User replied, let's remove the label
          puts "https://github.com/#{SLUG}/issues/#{issue.number} (#{issue.title}) was replied to by a different user"
          client.remove_label(SLUG, issue.number, AWAITING_REPLY)
        end
        smart_sleep
      elsif diff_in_months > ISSUE_WARNING
        return if issue.labels.find { |a| a.name == AWAITING_REPLY }

        puts "https://github.com/#{SLUG}/issues/#{issue.number} (#{issue.title}) is #{diff_in_months.round(1)} months old, pinging now"
        body = []
        body << "There hasn't been any activity on this issue recently. Due to the high number of incoming GitHub notifications, we have to clean some of the old issues, as many of them have already been resolved with the latest updates."
        body << "Please make sure to update to the latest `fastlane` version and check if that solves the issue. Let us know if that works for you by adding a comment :+1:"

        client.add_comment(SLUG, issue.number, body.join("\n\n"))
        client.add_labels_to_an_issue(SLUG, issue.number, [AWAITING_REPLY])
        smart_sleep
      end
    end

    def smart_sleep
      sleep 5
    end
  end
end

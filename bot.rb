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
    ISSUE_LOCK = 6 # lock all issues with no activity within the last 6 months
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
        next if issue.labels.collect { |a| a.name }.include?("feature") # we ignore all feature requests for now

        puts "Investigating issue ##{issue.number}..."
        process(issue)
        counter += 1
      end
      puts "[SUCCESS] I worked through #{counter} issues / PRs, much faster than human beings, bots will take over"
    end

    def process(issue)
      process_old(issue)
      process_inactive(issue)
      process_code_signing(issue)
    end

    def myself
      client.user.login
    end

    # Lock old, inactive conversations
    def process_old(issue)
      return if issue.locked # already locked, nothing to do here

      diff_in_months = (Time.now - issue.updated_at) / 60.0 / 60.0 / 24.0 / 30.0

      return if diff_in_months < ISSUE_LOCK

      puts "Locking conversations for https://github.com/#{SLUG}/issues/#{issue.number} since it hasn't been updated in #{diff_in_months.round} months"
      # Currently in beta https://developer.github.com/changes/2016-02-11-issue-locking-api/
      cmd = "curl 'https://api.github.com/repos/#{SLUG}/issues/#{issue.number}/lock' \
            -X PUT \
            -H 'Authorization: token #{ENV["GITHUB_API_TOKEN"]}' \
            -H 'Content-Length: 0' \
            -H 'Accept: application/vnd.github.the-key-preview'"
      `#{cmd} > /dev/null`
      puts "Done locking the conversation"
      smart_sleep
    end

    # Responsible for commenting to inactive issues, and closing them after a while
    def process_inactive(issue)
      diff_in_months = (Time.now - issue.updated_at) / 60.0 / 60.0 / 24.0 / 30.0

      warning_sent = !!issue.labels.find { |a| a.name == AWAITING_REPLY }
      if warning_sent && diff_in_months > ISSUE_CLOSED
        # We sent off a warning, but we have to check if the user replied
        if client.issue_comments(SLUG, issue.number).last.user.login == myself
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

    # Ask people to check out the code signing bot
    def process_code_signing(issue)
      return if issue.comments > 0 # we might have already replied, no bot necessary

      signing_words = ["signing", "provisioning"]
      body = issue.body + issue.title
      signing_related = signing_words.find_all do |keyword|
        body.downcase.include?(keyword)
      end
      return if signing_related.count == 0

      url = "https://docs.fastlane.tools/codesigning/GettingStarted/"
      puts "https://github.com/#{SLUG}/issues/#{issue.number} (#{issue.title}) might have something to do with code signing"
      body = []
      body << "It seems like this issue might be related to code signing :no_entry_sign:"
      body << "Have you seen our new [Code Signing Troubleshooting Guide](#{url})? It will help you resolve the most common code signing issues :+1:"

      client.add_comment(SLUG, issue.number, body.join("\n\n"))
    end

    def smart_sleep
      sleep 5
    end
  end
end

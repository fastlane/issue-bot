require 'octokit'
require 'pry'
require 'excon'
require 'colored'
require 'json'
require "./markdown_tableformatter"
module Fastlane
  class Bot
    SLUG = if ENV["REPO_SLUG"]
              ENV["REPO_SLUG"]
            else
              "fastlane/fastlane"
            end
    ISSUE_WARNING = 2
    ISSUE_CLOSED = 0.3 # plus the x months from ISSUE_WARNING
    ISSUE_LOCK = 6 # lock all issues with no activity within the last 6 months
    AWAITING_REPLY = "waiting-for-reply"
    AUTO_CLOSED = "auto-closed"
    TOOLS = []
    TOOLS << "fastlane_core"
    TOOLS << "gym"
    TOOLS << "cert"
    TOOLS << "credentials_manager"
    TOOLS << "danger-device_grid"
    TOOLS << "deliver"
    TOOLS << "fastlane"
    TOOLS << "frameit"
    TOOLS << "match"
    TOOLS << "pem"
    TOOLS << "pilot"
    TOOLS << "produce"
    TOOLS << "rakelib"
    TOOLS << "scan"
    TOOLS << "screengrab"
    TOOLS << "sigh"
    TOOLS << "snapshot"
    TOOLS << "spaceship"
    TOOLS << "supply"
    TOOLS << "watchbuild"

    def client
      @client ||= Octokit::Client.new(access_token: ENV["GITHUB_API_TOKEN"])
    end

    def start
      client.auto_paginate = true
      puts "Fetching issues from '#{SLUG}'..."

      client.issues(SLUG, per_page: 30, state: "all").each do |issue|
        next unless issue.pull_request.nil? # no PRs for now

        puts "Investigating issue ##{issue.number}..."
        process_open_issue(issue) if issue.state == "open"
        process_closed_issue(issue) if issue.state == "closed"
      end

      puts "[SUCCESS] I worked through issues / PRs, much faster than human beings, bots will take over"
    end

    def detect_tool_in_issue(issue)
      body = issue.body + issue.title
      tool_counter = {}
      total = 0
      TOOLS.each do | t |
        tool_counter[t] = body.scan(/(?=#{t})/).count
        total += tool_counter[t]
      end
      total_perc = {}
      tool_counter.each do | tool, cnt |
        total_perc[tool] = (cnt*100)  / total
      end
      
      total_perc = total_perc.sort_by {|_key, value| value}.reverse
      
      re = "most related tool(s) detected: "
      total_perc[0..2].each do | top_tool, v |
        re << "_#{top_tool}_,"
      end
      
      re
    end
      
    
    def process_open_issue(issue)
      bot_actions = []
      process_inactive(issue)

      return if issue.comments > 0 # there maybe already some bot replys
      bot_actions << process_code_signing(issue)
      bot_actions << process_env_check(issue)
      bot_actions << process_outdated_check(issue)
      bot_actions << process_legacy_build_api_check(issue)
      bot_actions << process_stacktrace_detector(issue)


      table = ""
        
      if bot_actions.length > 0
        table << "| Info | Description |\n"
        table << "|------|-------------|\n"
        bot_actions.each do |bot_reply|
          
          table << "| 🚫 | #{bot_reply.split("\n").join(" ")}|\n"
        end
        rendered_table = MarkdownTableFormatter.new table
        bot_reply = "We found some problems with your issue, in order to get your issue resolved as fast as possible. please try to fix the below informations:\n\n"
        bot_reply << rendered_table.to_md
        bot_reply << "\n\n "
        bot_reply << "__Please beware that this is automatically generated and maybe false/positive, i am just a 🤖 trying to help you!__\n\n"
        
        
        
        bot_reply << detect_tool_in_issue(issue)
        
        
        client.add_comment(SLUG, issue.number, bot_reply)
      end
      
    end

    def process_closed_issue(issue)
      lock_old_issues(issue)
    end

    def myself
      client.user.login
    end

    # Lock old, inactive conversations
    def lock_old_issues(issue)
      return if issue.locked # already locked, nothing to do here

      diff_in_months = (Time.now - issue.updated_at) / 60.0 / 60.0 / 24.0 / 30.0

      return if diff_in_months < ISSUE_LOCK

      puts "Locking conversations for https://github.com/#{SLUG}/issues/#{issue.number} since it hasn't been updated in #{diff_in_months.round} months"
      # Currently in beta https://developer.github.com/changes/2016-02-11-issue-locking-api/
      cmd = "curl 'https://api.github.com/repos/#{SLUG}/issues/#{issue.number}/lock' \
            -X PUT \
            -H 'Authorization: token #{ENV['GITHUB_API_TOKEN']}' \
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
    
    def process_outdated_check(issue)
      body = issue.body + issue.title
      if body.include?("Update availaible")
        puts "https://github.com/#{SLUG}/issues/#{issue.number} (#{issue.title}) has outdated fastlane gems"
        body = []
        body << "Seems you have some outdated gems, please try to update them in first place."
        return body.join("\n\n")
      end
    end
    
    def process_stacktrace_detector(issue) 
      
      
      puts "https://github.com/#{SLUG}/issues/#{issue.number} (#{issue.title}) has fastlane stacktrace"
      
      body = issue.body + issue.title
      stacktrace_tools = []
      stacktrace = body.scan(/lib\/(.*?)\/(.*?):([0-9]+)/i)
      
      stacktrace.each do | tool, file_in_lib, line_nr |
        
        if TOOLS.any? { |word| tool.include?(word) }
            # https://github.com/fastlane/fastlane/blob/master/cert/lib/cert/commands_generator.rb#L29
            stacktrace_tools << "[#{tool}/lib/#{tool}/#{file_in_lib}:#{line_nr}](https://github.com/fastlane/fastlane/blob/master/#{tool}/lib/#{tool}/#{file_in_lib}#L#{line_nr})"
        end
      end
      if stacktrace_tools.length > 0
        body = []
        body = "<details><summary>Found _fastlane_ stacktrace</summary> <ul>"
        stacktrace_tools.each do | tr |
          body << "<li>#{tr}</li>"
        end
        body << "</ul></details>"
      end
    end
    
    # check if `use_legacy_build_api` is used
    def process_legacy_build_api_check(issue)
      body = issue.body + issue.title
      if body.match(/use_legacy_build_api.*true/i)
        puts "https://github.com/#{SLUG}/issues/#{issue.number} (#{issue.title}) uses old legacy xcode build api"
        body = []
        body << "You probably using old xcode build api. `use_legacy_build_api` - please try to run your commands without this parameter (or setting it to false)"
        return body.join("\n\n")
      end
    end
    # Remind people to include `fastlane env`
    def process_env_check(issue)
      body = issue.body + issue.title
      unless body.include?("Loaded fastlane plugins")
        puts "https://github.com/#{SLUG}/issues/#{issue.number} (#{issue.title}) seems to be missing env report"
        body = []
        body << "It seems like you have not included the output of `fastlane env`."
        return body.join("\n\n")
      end
      return nil
    end

    # Ask people to check out the code signing bot
    def process_code_signing(issue)
      signing_words = ["signing", "provisioning"]
      body = issue.body + issue.title
      signing_related = signing_words.find_all do |keyword|
        body.downcase.include?(keyword)
      end
      return nil if signing_related.count == 0

      url = "https://docs.fastlane.tools/codesigning/getting-started/"
      puts "https://github.com/#{SLUG}/issues/#{issue.number} (#{issue.title}) might have something to do with code signing"
      body = []
      body << "It seems like this issue might be related to code signing :no_entry_sign:"
      body << "Please see [Code Signing Troubleshooting Guide](#{url})? It will help you resolve the most common code signing issues :+1:"
      return body.join("\n\n")
    end

    def smart_sleep
      sleep 5
    end
  end
end

require 'octokit'
require 'pry'
require 'excon'
require 'colored'
require 'json'

module Fastlane
  class Bot
    SLUG = "fastlane/fastlane"
    ISSUE_WARNING = 1.5 # in months
    ISSUE_CLOSED = 0.3 # plus the x months from ISSUE_WARNING
    ISSUE_LOCK = 2 # lock all issues with no activity within the last 3 months
    NEEDS_ATTENTION_PR_LIFESPAN_DAYS = 14 # threshold for marking a PR as needing attention

    # Labels
    AWAITING_REPLY = "status: waiting-for-reply"
    AUTO_CLOSED = "status: auto-closed"
    NEEDS_ATTENTION = 'status: needs-attention'
    REGRESSION = 'status: regression'
    RELEASED = 'status: released'
    INCLUDED_IN_NEXT_RELEASE = 'status: included-in-next-release'

    ACTION_CHANNEL_SLACK_WEB_HOOK_URL = ENV['ACTION_CHANNEL_SLACK_WEB_HOOK_URL']

    NEEDS_ATTENTION_PR_QUERY = "https://github.com/#{SLUG}/pulls?q=is%3Aopen+is%3Apr+label%3A%22#{NEEDS_ATTENTION}%22"

    attr_reader :logger

    def initialize(logger)
      @logger = logger
    end

    def client
      @client ||= Octokit::Client.new(access_token: ENV["GITHUB_API_TOKEN"])
    end

    def start(process: :issues)
      # Heroku is already complaining about memory size, and auto_paginate
      # makes the client bring all of the objects into memory at once. This
      # can only continue to get worse, since we look at every issue ever.
      client.auto_paginate = false

      logger.info("Fetching release information for '#{SLUG}'...")
      # We only want to consider the 5 most recent releases, so no sense downloading more data than that.
      # We consider the 5 most recent in case we have done multiple releases since the last run of the bot.
      releases = client.releases(SLUG, per_page: 5)
      prs_to_releases = map_prs_to_releases(releases)

      logger.info("Fetching issues and PRs from '#{SLUG}'...")

      needs_attention_prs = []

      # Doing pagination ourself is a pain, but it's important for keeping a
      # reasonable memory footprint
      page = 1
      issues_page = fetch_issues(page)

      while issues_page && issues_page.any?
        # It's important that we check this immediately, as calls we make during
        # processing will affect the last_response
        has_next_page = !!client.last_response.rels[:next]

        issues_page.each do |issue|
          if process == :issues && issue.pull_request.nil?
            logger.info("Investigating issue ##{issue.number}...")
            process_open_issue(issue) if issue.state == "open"
            process_closed_issue(issue) if issue.state == "closed"
          elsif process == :prs && issue.pull_request
            logger.info("Investigating PR ##{issue.number}...")
            process_open_pr(issue, needs_attention_prs) if issue.state == "open"
            process_closed_pr(issue, prs_to_releases) if issue.state == "closed" # includes merged
          elsif process == :regressions
            # .to_s in case something is nil
            if (issue.title.to_s + issue.body.to_s).downcase.include?("regression") && !has_label?(issue, REGRESSION)
              client.add_labels_to_an_issue(SLUG, issue.number, [REGRESSION])

              post_body = {
                text: "New PR/Issue containing the word \"regression\": #{issue.html_url}"
              }.to_json
              logger.info("Found regression on GH issue/PR #{issue.html_url}")

              response = Excon.post(ACTION_CHANNEL_SLACK_WEB_HOOK_URL, body: post_body, headers: { "Content-Type" => "application/json" })
              if response.status == 200
                logger.info("Successfully notified the Slack room about PRs that need attention")
              else
                logger.info("Failed to notify the Slack room about PRs that need attention")
              end
            end
          end
        end

        page += 1
        # If there's a next page, keep going
        issues_page = has_next_page ? fetch_issues(page) : nil
      end

      notify_action_channel_about(needs_attention_prs)

      logger.info("[SUCCESS] I worked through issues / PRs, much faster than human beings, bots will take over")
    end

    def fetch_issues(page = 1)
      # issues includes PRs, and since the pull_requests API doesn't include
      # labels, it's actually important that we query everything this way!
      client.issues(SLUG, per_page: 100, state: "all", page: page)
    end

    def process_open_issue(issue)
      bot_actions = []
      process_inactive(issue)

      return if issue.comments > 0 # there maybe already some bot replies
      bot_actions << process_code_signing(issue)
      bot_actions << process_env_check(issue)

      bot_actions.each do |bot_reply|
        client.add_comment(SLUG, issue.number, bot_reply) if bot_reply.to_s.length > 0
        smart_sleep
      end
    end

    def process_closed_issue(issue)
      lock_old_issues(issue)
    end

    def process_open_pr(pr, needs_attention_prs)
      days_since_created = (Time.now - pr.created_at) / 60.0 / 60.0 / 24.0

      should_have_needs_attention_label = days_since_created > NEEDS_ATTENTION_PR_LIFESPAN_DAYS
      has_needs_attention_label = has_label?(pr, NEEDS_ATTENTION)

      if should_have_needs_attention_label || has_needs_attention_label
        add_needs_attention_to(pr) unless has_needs_attention_label
        needs_attention_prs << pr
      end
    end

    def process_closed_pr(pr, prs_to_releases)
      remove_needs_attention_from(pr) if has_label?(pr, NEEDS_ATTENTION)

      # When we mark something as released, it doesn't update the already in-memory representation
      # of that PR. So we need to keep track of whether we just marked as released, so that we don't
      # immediately also mark it as merged.
      just_marked_released = false

      if prs_to_releases.key?(pr.number.to_s) && !has_label?(pr, RELEASED)
        mark_as_released(pr, prs_to_releases)
        just_marked_released = true
      end

      # If we just marked this PR as released, we can skip saying that it was merged
      if !just_marked_released && should_mark_as_merged?(pr)
        mark_as_merged(pr)
      end

      # Lock old, inactive PRs (same as with issues)
      # only for PRs that are merged of course
      lock_old_issues(pr)
    end

    def should_mark_as_merged?(pr)
      now = Time.now

      # In order to avoid marking all PRs since the beginning of time, we need to make sure
      # that the PR was merged recently. However, the merged_at field is not available on the
      # basic "issue" object from GitHub (our PR object is actually an "issue")
      #
      # To get the merged_at date, we'll need to make another web request, so to cut down on the
      # number of requests that get made, we'll first check the closed_at date to eliminate
      # PRs we don't need to consider.
      hours_pr_was_closed_ago = (now - pr.closed_at) / 60.0 / 60.0
      return false unless hours_pr_was_closed_ago < 24

      # Now we're reasonably sure we need to check the merged_at date for this PR, so fetch the details
      pr_details = client.pull_request(SLUG, pr.number) # as the issue metadata doesn't contain that information
      # If the PR wasn't merged, we don't need to consider it
      return false unless pr_details.merged_at

      # The final stage of our safety check skips PRs that were merged, but not recently
      hours_pr_was_merged_ago = (now - pr_details.merged_at) / 60.0 / 60.0
      return false unless hours_pr_was_merged_ago < 24

      return !has_label?(pr, RELEASED) && !has_label?(pr, INCLUDED_IN_NEXT_RELEASE)
    end

    def notify_action_channel_about(needs_attention_prs)
      return unless needs_attention_prs.any?

      logger.info("Notifying the Slack room about PRs that need attention...")

      pr_count = needs_attention_prs.size
      pr_pluralized = pr_count == 1 ? "PR" : "PRs"
      verb_pluralized = pr_count == 1 ? "has" : "have"

      pr_query_link = "<#{NEEDS_ATTENTION_PR_QUERY}|#{pr_count} #{pr_pluralized}>"

      post_body = {
        text: "#{pr_query_link} #{verb_pluralized} been alive for more than #{NEEDS_ATTENTION_PR_LIFESPAN_DAYS} days."
      }.to_json

      response = Excon.post(ACTION_CHANNEL_SLACK_WEB_HOOK_URL, body: post_body, headers: { "Content-Type" => "application/json" })

      if response.status == 200
        logger.info("Successfully notified the Slack room about PRs that need attention")
      else
        logger.info("Failed to notify the Slack room about PRs that need attention")
      end
    end

    def myself
      client.user.login
    end

    def has_label?(issue, label_name)
      issue.labels? && !!issue.labels.find { |label| label.name == label_name }
    end

    def add_needs_attention_to(issue)
      logger.info("Adding #{NEEDS_ATTENTION} label on ##{issue.number}")
      client.add_labels_to_an_issue(SLUG, issue.number, [NEEDS_ATTENTION])
    end

    def remove_needs_attention_from(issue)
      logger.info("Removing #{NEEDS_ATTENTION} label on ##{issue.number}")
      client.remove_label(SLUG, issue.number, NEEDS_ATTENTION)
    end

    def mark_as_merged(pr)
      congrats_on_merging = []
      congrats_on_merging << "Hey @#{pr.user.login} :wave:\n"
      congrats_on_merging << "Thank you for your contribution to _fastlane_ and congrats on getting this pull request merged :tada:"
      congrats_on_merging << "The code change now lives in the `master` branch, however it wasn't released to [RubyGems](https://rubygems.org/gems/fastlane) yet."
      congrats_on_merging << "We usually ship about once a week, and your PR will be included in the next one.\n"
      congrats_on_merging << "Please let us know if this change requires an immediate release by adding a comment here :+1:"
      congrats_on_merging << "We'll notify you once we shipped a new release with your changes :rocket:"
      client.add_comment(SLUG, pr.number, congrats_on_merging.join("\n"))
      client.add_labels_to_an_issue(SLUG, pr.number, [INCLUDED_IN_NEXT_RELEASE])
    end

    def mark_as_released(pr, prs_to_releases)
      version = prs_to_releases[pr.number.to_s]
      release_url = "https://github.com/#{SLUG}/releases/tag/#{version}"

      logger.info("Marking #{pr.number} as having been released in version #{version}")

      # This doesn't wind up modifying the in-memory object, so we will still find this label applied
      # when we check for it in the next step.
      client.remove_label(SLUG, pr.number, INCLUDED_IN_NEXT_RELEASE) if has_label?(pr, INCLUDED_IN_NEXT_RELEASE)
      client.add_labels_to_an_issue(SLUG, pr.number, [RELEASED])
      client.add_comment(SLUG, pr.number, "Congratulations! :tada: This was released as part of [_fastlane_ #{version}](#{release_url}) :rocket:")
      smart_sleep
    end

    # Lock old, inactive conversations
    def lock_old_issues(issue)
      return if issue.locked # already locked, nothing to do here

      diff_in_months = (Time.now - issue.updated_at) / 60.0 / 60.0 / 24.0 / 30.0

      return if diff_in_months < ISSUE_LOCK

      logger.info("Locking conversations for https://github.com/#{SLUG}/issues/#{issue.number} since it hasn't been updated in #{diff_in_months.round} months")
      # Currently in beta https://developer.github.com/changes/2016-02-11-issue-locking-api/
      cmd = "curl 'https://api.github.com/repos/#{SLUG}/issues/#{issue.number}/lock' \
            -X PUT \
            -H 'Authorization: token #{ENV['GITHUB_API_TOKEN']}' \
            -H 'Content-Length: 0' \
            -H 'Accept: application/vnd.github.the-key-preview'"
      `#{cmd} > /dev/null`
      logger.info("Done locking the conversation")
      smart_sleep
    end

    # Responsible for commenting to inactive issues, and closing them after a while
    def process_inactive(issue)
      diff_in_months = (Time.now - issue.updated_at) / 60.0 / 60.0 / 24.0 / 30.0

      warning_sent = !!issue.labels.find { |a| a.name == AWAITING_REPLY }
      if warning_sent && diff_in_months > ISSUE_CLOSED
        # We sent off a warning, but we have to check if the user replied
        if last_responding_user(issue) == myself
          # No reply from the user, let's close the issue
          logger.info("https://github.com/#{SLUG}/issues/#{issue.number} (#{issue.title}) is #{diff_in_months.round(1)} months old, closing now")
          body = []
          body << "This issue will be auto-closed because there hasn't been any activity for a few months. Feel free to [open a new one](https://github.com/#{SLUG}/issues/new) if you still experience this problem :+1:"
          client.add_comment(SLUG, issue.number, body.join("\n\n"))
          client.close_issue(SLUG, issue.number)
          client.add_labels_to_an_issue(SLUG, issue.number, [AUTO_CLOSED])
        else
          # User replied, let's remove the label
          logger.info("https://github.com/#{SLUG}/issues/#{issue.number} (#{issue.title}) was replied to by a different user")
          client.remove_label(SLUG, issue.number, AWAITING_REPLY)
        end
        smart_sleep
      elsif diff_in_months > ISSUE_WARNING
        return if issue.labels.find { |a| a.name == AWAITING_REPLY }

        logger.info("https://github.com/#{SLUG}/issues/#{issue.number} (#{issue.title}) is #{diff_in_months.round(1)} months old, pinging now")
        body = []
        body << "There hasn't been any activity on this issue recently. Due to the high number of incoming GitHub notifications, we have to clean some of the old issues, as many of them have already been resolved with the latest updates."
        body << "Please make sure to update to the latest `fastlane` version and check if that solves the issue. Let us know if that works for you by adding a comment :+1:"

        client.add_comment(SLUG, issue.number, body.join("\n\n"))
        client.add_labels_to_an_issue(SLUG, issue.number, [AWAITING_REPLY])
        smart_sleep
      end
    end

    # Remind people to include `fastlane env`

    def process_env_check(issue)
      body = issue.body + issue.title
      unless body.include?("Loaded fastlane plugins")
        logger.info("https://github.com/#{SLUG}/issues/#{issue.number} (#{issue.title}) seems to be missing env report")
        body = []
        body << "It seems like you have not included the output of `fastlane env`"
        body << "To make it easier for us help you resolve this issue, please update the issue to include the output of `fastlane env` :+1:"
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
      logger.info("https://github.com/#{SLUG}/issues/#{issue.number} (#{issue.title}) might have something to do with code signing")
      body = []
      body << "It seems like this issue might be related to code signing :no_entry_sign:"
      body << "Have you seen our new [Code Signing Troubleshooting Guide](#{url})? It will help you resolve the most common code signing issues :+1:"
      return body.join("\n\n")
    end

    def last_responding_user(issue)
      client.issue_comments(SLUG, issue.number)
      link_to_last_page = client.last_response.rels[:last]
      last_comment_page = link_to_last_page.get.data
      last_comment_page.last.user.login
    end

    def smart_sleep
      sleep 5
    end

    # Create a hash of PR numbers (as strings) to release tag names indicating in which release
    # a given PR was mentioned in the release notes. For example:
    #
    # {
    #   "8594"=>"2.22.0",
    #   "8592"=>"2.22.0",
    #   "8595"=>"2.22.0",
    #   "8593"=>"2.21.0",
    #   "8596"=>"2.21.0",
    #   "8564"=>"2.20.0"
    # }
    def map_prs_to_releases(releases)
      prs_to_releases = {}
      releases = releases.select { |r| !r.draft && !r.prerelease && !r.body.nil? && !r.tag_name.nil? }
      releases.each do |release|
        collect_pr_references_from_release(release, prs_to_releases)
      end
      prs_to_releases
    end

    # Populate the provided prs_to_releases hash with the PR references found in the given release's
    # release notes
    def collect_pr_references_from_release(release, prs_to_releases)
      release.body.split("\n").each do |line|
        collect_pr_references_from_line(line, release.tag_name, prs_to_releases)
      end
    end

    def collect_pr_references_from_line(line, release_name, prs_to_releases)
      # matches:
      #   (#8324)
      #   (#8324,#8325)
      #   (#8324, #8325)
      #   (#8324,#8325,#8326)
      #   (#8324, #8325, #8326)
      # etc.
      # captures inside the parens
      #   #8324, #8325, #8326
      pr_numbers_match = line.match(/\((#\d+(?:,\s*#\d+)*)\)/)
      if pr_numbers_match
        pr_numbers = pr_numbers_match[1].split(/,\s*/).map { |n| n.sub('#', '') }
        pr_numbers.each do |pr_number|
          prs_to_releases[pr_number] = release_name
        end
      end
    end
  end
end

require 'sinatra'
require 'json'
require 'octokit'

def client
  @client ||= Octokit::Client.new(access_token: ENV["GITHUB_API_TOKEN"])
end

post '/payload' do
  allowed_users = ["hjanuschka", "KrauseFx", "mfurtak", "tkburner", "ohwutup", "asfalcone"]
  slug = ENV["SLUG"] || "fastlane/fastlane"
  bot_user = ENV["BOT_USER"]
  payload = JSON.parse(request.body.read)

  if payload["action"] == "created"
    puts "HEADER FOUND"
    body = payload["comment"]["body"]
    issue = payload["issue"]
    comment = payload["comment"]
    puts body
    if body.include?("@#{bot_user}")
      if allowed_users.include?(comment["user"]["login"])

        puts "BOT mentioned"

        if body.include?("close issue")
          # close the issue
          client.close_issue(slug, issue["number"])
          # remove command/comment
          client.delete_comment(slug, comment["id"])
        end

        if body.include?("lock issue")
          # lock the issue
          client.lock_issue(slug, issue["number"])
          # remove command/comment
          client.delete_comment(slug, comment["id"])
        end

        if body.include?("reopen issue")
          # reopen the issue
          client.reopen_issue(slug, issue["number"])
          # remove command/comment
          client.delete_comment(slug, comment["id"])
        end

        if body.include?("add tags")
          # add tags: [ bug, question, invalid ]
          tags = body.scan(/.*\[(.*?)\]/).first.first.split(",")
          tags.each do |t|
            t.delete!(" ")
            t_already_set = !!issue["labels"].find { |a| a.name == t }
            unless t_already_set
              puts "adding tag #{t}"
              client.add_labels_to_an_issue(slug, issue["number"], [t])
            end
            # remove this command/comment :)
            client.delete_comment(slug, comment["id"])
          end
        end

        if body.include?("remove tags")
          # add tags: [ bug, question, invalid ]
          tags = body.scan(/.*\[(.*?)\]/).first.first.split(",")
          tags.each do |t|
            t.delete!(" ")
            client.remove_label(slug, issue["number"], t)
            # remove this command/comment :)
            client.delete_comment(slug, comment["id"])
          end
        end

      end

    end
  end
end

get '/' do
  "Hello World!"
end

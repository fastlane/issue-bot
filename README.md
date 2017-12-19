# issue-bot

This bot is responsible for commenting on GitHub issues that haven't had any activity for multiple months. 

Due to the fast nature of [fastlane](https://fastlane.tools), issues often can't be reproduced anymore after 2-3 months of inactivity. 

Please note that the issue-bot system run by the `fastlane` core team does not automatically deploy code changes made to this repository. When merging changes to the repository, please let a member of the `fastlane` core team know (via Slack or at-mention in the GitHub pull request), so that they can manually deploy your code change.

## Development

1. You can use `rake` to easily run a couple of tasks.

    Run `bundle exec rake --tasks` _(or simply `-T`)_ to get a list of all the available tasks and their description.

    You run a task using `bundle exec rake <task name>`.

2. You can also use `pry` to test different methods from the `Bot` class. For example, to test the processing of new issues:

    1. `cd` into the repository's project
    2. run `bundle exec pry`
    3. execute `require "logger"`
    4. execute `load "bot.rb"`
    5. execute `Fastlane::Bot.new(Logger.new(STDOUT)).start(process: :issues)`

    After you modify the bot, you execute `load "bot.rb"` again for the new changes take effect.

3. If you want to test it with actual data, you need to create a GitHub access token by going to https://github.com/settings/tokens, generating a new token and following these steps:

    1. create a testing GitHub project
    2. update the `SLUG` constant with this new project's path (`<username>/<project name>`)
    3. run `export GITHUB_API_TOKEN=<token>`
    4. run the steps `2.ii` - `2.v`

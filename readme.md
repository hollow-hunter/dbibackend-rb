DBI backend (in Ruby)
===

Computer server for games installation into Nintendo Switch.    
It's basically a Ruby version of the [original DBI backend made in python](https://github.com/rashevskyv/dbi).

# Requirements
- Ruby 3.x

# Usage
1. Install dependencies with bundler
```
bundle install
```
2. Run the script passing the path to your games directory
```
bundle exec ruby backend.rb games/
```

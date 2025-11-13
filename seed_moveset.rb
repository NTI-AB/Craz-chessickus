#!/usr/bin/env ruby
require 'sqlite3'
require_relative 'lib/move_rules_store'

db_path = File.expand_path('moveset.db', __dir__)
db = SQLite3::Database.new(db_path)
db.results_as_hash = true

MoveRulesStore.ensure_schema!(db)
MoveRulesStore.reset!(db)

count = db.get_first_value('SELECT COUNT(*) FROM move_rules').to_i
puts "Seeded #{count} move rules into #{db_path}"

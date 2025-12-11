#!/usr/bin/env ruby
require 'sqlite3'
require_relative 'lib/move_rules_store'

db_path = File.expand_path('database.db', __dir__)
db = SQLite3::Database.new(db_path)
db.results_as_hash = true

MoveRulesStore.ensure_schema!(db)
MoveRulesStore.reset!(db)

count = MoveRulesStore.pattern_count(db)
puts "Seeded #{count} move patterns into #{db_path}"

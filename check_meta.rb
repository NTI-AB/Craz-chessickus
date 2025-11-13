require 'sqlite3'
db = SQLite3::Database.new('database.db')
puts db.get_first_value("SELECT value FROM meta WHERE key = 'board_size'")

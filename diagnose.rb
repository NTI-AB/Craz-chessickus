require_relative 'app'
require 'rack/mock'

app = Sinatra::Application
req = Rack::MockRequest.new(app)

# ensure board reset to size 8 for clarity
db = SQLite3::Database.new('database.db')
db.execute("UPDATE meta SET value = '8' WHERE key = 'board_size'")
reset_board
puts "turn: #{get_turn}"

resp = req.post('/move', params: { 'from' => '0,6', 'to' => '0,5', 'player' => 'white' })
puts "white move status: #{resp.status}"
puts "turn: #{get_turn}"

resp2 = req.post('/move', params: { 'from' => '0,1', 'to' => '0,2', 'player' => 'black' })
puts "black move status: #{resp2.status}"
puts "turn: #{get_turn}"

require 'sinatra'
require 'sinatra/reloader' if development?
require 'sqlite3'
require 'json'
require_relative 'lib/move_rules_store'

set :bind, '0.0.0.0'

# --- Database setup ---
DB = SQLite3::Database.new('database.db')
DB.results_as_hash = true

DB.execute <<~SQL
  CREATE TABLE IF NOT EXISTS pieces (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT,
    symbol TEXT,
    color TEXT,
    x INTEGER,
    y INTEGER
  );
SQL

DB.execute <<~SQL
  CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value TEXT
  );
SQL

MOVES_DB = SQLite3::Database.new('moveset.db')
MOVES_DB.results_as_hash = true
MoveRulesStore.ensure_schema!(MOVES_DB)

# Ensure defaults exist
def ensure_meta_default(key, default)
  existing = DB.get_first_value('SELECT value FROM meta WHERE key = ?', [key])
  DB.execute('INSERT INTO meta (key, value) VALUES (?, ?)', [key, default]) if existing.nil?
end

ensure_meta_default('turn', 'white')
ensure_meta_default('board_size', '8')

MoveRulesStore.ensure_seeded!(MOVES_DB)

# --- Helper methods ---
PLAYER_COLORS = %w[white black].freeze

def get_pieces
  DB.execute('SELECT * FROM pieces')
end

def piece_at(x, y)
  DB.get_first_row('SELECT * FROM pieces WHERE x = ? AND y = ?', [x, y])
end

def board_size
  (DB.get_first_value('SELECT value FROM meta WHERE key = ?', ['board_size']) || '8').to_i
end

def reset_board
  DB.execute('DELETE FROM pieces')

  size = board_size
  size.times do |x|
    DB.execute('INSERT INTO pieces (name, symbol, color, x, y) VALUES (?, ?, ?, ?, ?)', ['Pawn', 'P', 'white', x, size - 2])
    DB.execute('INSERT INTO pieces (name, symbol, color, x, y) VALUES (?, ?, ?, ?, ?)', ['Pawn', 'p', 'black', x, 1])
  end

  # Default back rank layout if space allows (size >= 8): R N B Q K B N R
  if size >= 8
    back = [
      ['Rook', 0], ['Knight', 1], ['Bishop', 2], ['Queen', 3], ['King', 4], ['Bishop', 5], ['Knight', 6], ['Rook', 7]
    ]
    back.each do |name, x|
      next if x >= size
      DB.execute('INSERT INTO pieces (name, symbol, color, x, y) VALUES (?, ?, ?, ?, ?)', [name, name[0], 'white', x, size - 1])
      DB.execute('INSERT INTO pieces (name, symbol, color, x, y) VALUES (?, ?, ?, ?, ?)', [name, name[0].downcase, 'black', x, 0])
    end
  else
    # Fallback for small sizes: just place kings at center
    kx = size / 2
    DB.execute('INSERT INTO pieces (name, symbol, color, x, y) VALUES (?, ?, ?, ?, ?)', ['King', 'K', 'white', kx, size - 1])
    DB.execute('INSERT INTO pieces (name, symbol, color, x, y) VALUES (?, ?, ?, ?, ?)', ['King', 'k', 'black', kx, 0])
  end

  DB.execute('INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value', ['turn', 'white'])
end

def get_turn
  result = DB.get_first_value('SELECT value FROM meta WHERE key = ?', 'turn')
  result || 'white'
end

def switch_turn
  new_turn = get_turn == 'white' ? 'black' : 'white'
  DB.execute('UPDATE meta SET value = ? WHERE key = ?', [new_turn, 'turn'])
end

def normalize_player_color(value)
  color = value.to_s.downcase
  PLAYER_COLORS.include?(color) ? color : 'white'
end

def player_path(color)
  "/play/#{normalize_player_color(color)}"
end

def valid_moves_for_piece(piece)
  return [] unless piece

  x = piece['x'].to_i
  y = piece['y'].to_i
  size = board_size

  rules = MOVES_DB.execute('SELECT * FROM move_rules WHERE name = ? AND (color IS NULL OR color = ?)', [piece['name'], piece['color']])
  moves = []

  rules.each do |r|
    dx = r['dx'].to_i
    dy = r['dy'].to_i
    steps = r['max_steps'].to_i
    kind = r['kind']

    cx = x
    cy = y
    1.upto(steps) do
      tx = cx + dx
      ty = cy + dy
      break if tx < 0 || ty < 0 || tx >= size || ty >= size

      occ = piece_at(tx, ty)
      case kind
      when 'move_only'
        break if occ
        moves << [tx, ty]
      when 'capture_only'
        moves << [tx, ty] if occ && occ['color'] != piece['color']
        break
      else
        if occ
          moves << [tx, ty] if occ['color'] != piece['color']
          break
        else
          moves << [tx, ty]
        end
      end

      cx = tx
      cy = ty
    end
  end

  moves
end

before do
  MoveRulesStore.ensure_seeded!(MOVES_DB)
end

# --- Routes ---
get '/' do
  redirect '/play/white'
end

get '/play/:color' do
  color = params[:color].to_s.downcase
  halt 404 unless PLAYER_COLORS.include?(color)

  @pieces = get_pieces
  @turn = get_turn
  @board_size = board_size
  @rules_count = MOVES_DB.get_first_value('SELECT COUNT(*) FROM move_rules').to_i
  @player_color = color
  @board_orientation = color == 'black' ? :black : :white
  slim :index
end

post '/move' do
  from_x, from_y = params[:from].to_s.split(',').map(&:to_i)
  to_x, to_y = params[:to].to_s.split(',').map(&:to_i)
  player = normalize_player_color(params[:player])

  piece = piece_at(from_x, from_y)
  halt 404 unless piece
  halt 403 unless piece['color'] == player
  halt 403 unless get_turn == player

  moves = valid_moves_for_piece(piece)
  halt 400 unless moves.include?([to_x, to_y])

  DB.execute('DELETE FROM pieces WHERE x = ? AND y = ?', [to_x, to_y]) # capture
  DB.execute('UPDATE pieces SET x = ?, y = ? WHERE id = ?', [to_x, to_y, piece['id']])
  switch_turn

  redirect player_path(player)
end

post '/reset' do
  player = normalize_player_color(params[:player])
  reset_board
  redirect player_path(player)
end

post '/board_size' do
  player = normalize_player_color(params[:player])
  size = params[:size].to_i
  size = 4 if size < 4
  size = 20 if size > 20
  DB.execute('INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value', ['board_size', size.to_s])
  reset_board
  redirect player_path(player)
end

get '/valid_moves' do
  content_type :json
  x = params[:x].to_i
  y = params[:y].to_i
  p = piece_at(x, y)
  halt 200, { moves: [] }.to_json unless p
  moves = valid_moves_for_piece(p)
  { moves: moves }.to_json
end

get '/state' do
  content_type :json
  { turn: get_turn, board_size: board_size }.to_json
end

# --- Move rules management ---
get '/move_rules' do
  content_type :json
  rules = MOVES_DB.execute('SELECT * FROM move_rules ORDER BY name, color, dx, dy')
  { count: rules.size, rules: rules }.to_json
end

post '/move_rules' do
  content_type :json
  name = params[:name]
  color = params[:color]
  color = nil if color == ''
  dx = params[:dx].to_i
  dy = params[:dy].to_i
  max_steps = (params[:max_steps] || '1').to_i
  kind = params[:kind] || 'normal'

  halt 400, { error: 'name required' }.to_json if name.to_s.strip.empty?
  halt 400, { error: 'kind required' }.to_json if kind.to_s.strip.empty?

  MOVES_DB.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)', [name, color, dx, dy, max_steps, kind])
  rule = MOVES_DB.get_first_row('SELECT * FROM move_rules WHERE name=? AND IFNULL(color,"")=IFNULL(?,"") AND dx=? AND dy=? AND max_steps=? AND kind=?', [name, color, dx, dy, max_steps, kind])
  status 201
  rule.to_json
end

post '/move_rules/seed_defaults' do
  MoveRulesStore.ensure_seeded!(MOVES_DB)
  player = normalize_player_color(params[:player])
  redirect player_path(player)
end

post '/move_rules/reset_defaults' do
  MoveRulesStore.reset!(MOVES_DB)
  player = normalize_player_color(params[:player])
  redirect player_path(player)
end

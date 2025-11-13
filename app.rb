require 'sinatra'
require 'sinatra/reloader' if development?
require 'sqlite3'
require 'json'

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

# Movement rules for pieces
DB.execute <<~SQL
  CREATE TABLE IF NOT EXISTS move_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    color TEXT,
    dx INTEGER NOT NULL,
    dy INTEGER NOT NULL,
    max_steps INTEGER NOT NULL DEFAULT 1,
    kind TEXT NOT NULL
  );
SQL

# Ensure uniqueness to avoid duplicate default rules
DB.execute <<~SQL
  CREATE UNIQUE INDEX IF NOT EXISTS idx_move_rules_uniqueness
  ON move_rules(name, IFNULL(color, ''), dx, dy, max_steps, kind);
SQL

# Ensure defaults exist
def ensure_meta_default(key, default)
  existing = DB.get_first_value('SELECT value FROM meta WHERE key = ?', [key])
  DB.execute('INSERT INTO meta (key, value) VALUES (?, ?)', [key, default]) if existing.nil?
end

ensure_meta_default('turn', 'white')
ensure_meta_default('board_size', '8')

def seed_default_move_rules
  # King: 8 directions, 1 step
  [-1, 0, 1].each do |dx|
    [-1, 0, 1].each do |dy|
      next if dx == 0 && dy == 0
      DB.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)',
                 ['King', nil, dx, dy, 1, 'normal'])
    end
  end

  # Pawn forward and capture (color-specific)
  DB.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)', ['Pawn', 'white', 0, -1, 1, 'move_only'])
  DB.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)', ['Pawn', 'white', -1, -1, 1, 'capture_only'])
  DB.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)', ['Pawn', 'white', 1, -1, 1, 'capture_only'])
  DB.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)', ['Pawn', 'black', 0, 1, 1, 'move_only'])
  DB.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)', ['Pawn', 'black', -1, 1, 1, 'capture_only'])
  DB.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)', ['Pawn', 'black', 1, 1, 1, 'capture_only'])

  # Rook: orthogonal sliding
  [[1,0],[-1,0],[0,1],[0,-1]].each do |dx, dy|
    DB.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)', ['Rook', nil, dx, dy, 99, 'normal'])
  end
  # Bishop: diagonal sliding
  [[1,1],[1,-1],[-1,1],[-1,-1]].each do |dx, dy|
    DB.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)', ['Bishop', nil, dx, dy, 99, 'normal'])
  end
  # Queen: rook + bishop sliding
  [[1,0],[-1,0],[0,1],[0,-1],[1,1],[1,-1],[-1,1],[-1,-1]].each do |dx, dy|
    DB.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)', ['Queen', nil, dx, dy, 99, 'normal'])
  end
  # Knight: L-shapes
  [[1,2],[2,1],[2,-1],[1,-2],[-1,-2],[-2,-1],[-2,1],[-1,2]].each do |dx, dy|
    DB.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)', ['Knight', nil, dx, dy, 1, 'normal'])
  end
end

# Always ensure defaults exist (idempotent)
seed_default_move_rules

# --- Helper methods ---
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

# --- Routes ---
get '/' do
  @pieces = get_pieces
  @turn = get_turn
  @board_size = board_size
  @rules_count = DB.get_first_value('SELECT COUNT(*) FROM move_rules').to_i
  slim :index
end

post '/move' do
  from_x, from_y = params[:from].split(',').map(&:to_i)
  to_x, to_y = params[:to].split(',').map(&:to_i)

  piece = DB.get_first_row('SELECT * FROM pieces WHERE x = ? AND y = ?', [from_x, from_y])
  if piece
    DB.execute('DELETE FROM pieces WHERE x = ? AND y = ?', [to_x, to_y]) # capture
    DB.execute('UPDATE pieces SET x = ?, y = ? WHERE id = ?', [to_x, to_y, piece['id']])
    switch_turn
  end

  redirect '/'
end

post '/reset' do
  reset_board
  redirect '/'
end

post '/board_size' do
  size = params[:size].to_i
  size = 4 if size < 4
  size = 20 if size > 20
  DB.execute('INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value', ['board_size', size.to_s])
  reset_board
  redirect '/'
end

get '/valid_moves' do
  content_type :json
  x = params[:x].to_i
  y = params[:y].to_i
  p = piece_at(x, y)
  halt 200, { moves: [] }.to_json unless p

  size = board_size
  rules = DB.execute('SELECT * FROM move_rules WHERE name = ? AND (color IS NULL OR color = ?)', [p['name'], p['color']])

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
      if kind == 'move_only'
        if occ
          break
        else
          moves << [tx, ty]
        end
      elsif kind == 'capture_only'
        if occ && occ['color'] != p['color']
          moves << [tx, ty]
        end
        break
      else
        if occ
          if occ['color'] != p['color']
            moves << [tx, ty]
          end
          break
        else
          moves << [tx, ty]
        end
      end

      cx = tx
      cy = ty
    end
  end

  { moves: moves }.to_json
end

# --- Move rules management ---
get '/move_rules' do
  content_type :json
  rules = DB.execute('SELECT * FROM move_rules ORDER BY name, color, dx, dy')
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

  DB.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)', [name, color, dx, dy, max_steps, kind])
  rule = DB.get_first_row('SELECT * FROM move_rules WHERE name=? AND IFNULL(color,"")=IFNULL(?,"") AND dx=? AND dy=? AND max_steps=? AND kind=?', [name, color, dx, dy, max_steps, kind])
  status 201
  rule.to_json
end

post '/move_rules/seed_defaults' do
  seed_default_move_rules
  redirect '/'
end

post '/move_rules/reset_defaults' do
  DB.execute('DELETE FROM move_rules')
  seed_default_move_rules
  redirect '/'
end

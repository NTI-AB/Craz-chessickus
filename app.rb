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
    y INTEGER,
    move_count INTEGER NOT NULL DEFAULT 0
  );
SQL

DB.execute <<~SQL
  CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value TEXT
  );
SQL

def ensure_column(db, table, column, definition_sql)
  columns = db.table_info(table).map { |c| c['name'] }
  return if columns.include?(column)
  db.execute("ALTER TABLE #{table} ADD COLUMN #{definition_sql}")
end

ensure_column(DB, 'pieces', 'move_count', 'move_count INTEGER NOT NULL DEFAULT 0')
DB.execute('UPDATE pieces SET move_count = 0 WHERE move_count IS NULL')

MoveRulesStore.ensure_schema!(DB)
MOVE_RULES_VERSION = 2
PLAYER_COLORS = %w[white black].freeze

# Ensure defaults exist
def ensure_meta_default(key, default)
  existing = DB.get_first_value('SELECT value FROM meta WHERE key = ?', [key])
  DB.execute('INSERT INTO meta (key, value) VALUES (?, ?)', [key, default]) if existing.nil?
end

def ensure_move_rules_version!(version)
  stored = DB.get_first_value('SELECT value FROM meta WHERE key = ?', ['move_rules_version']).to_i
  return if stored >= version

  MoveRulesStore.seed_defaults(DB)
  DB.execute('INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value', ['move_rules_version', version.to_s])
end

ensure_meta_default('turn', 'white')
ensure_meta_default('board_size', '8')

MoveRulesStore.ensure_seeded!(DB)
ensure_move_rules_version!(MOVE_RULES_VERSION)

# --- Helper methods ---

def normalize_piece(row)
  return nil unless row

  row = row.transform_keys(&:to_s)
  row['x'] = row['x'].to_i
  row['y'] = row['y'].to_i
  row['move_count'] = (row['move_count'] || 0).to_i
  row
end

def pieces_state
  DB.execute('SELECT * FROM pieces').map { |p| normalize_piece(p) }
end

def get_pieces
  pieces_state
end

def piece_at(x, y)
  row = DB.get_first_row('SELECT * FROM pieces WHERE x = ? AND y = ?', [x, y])
  normalize_piece(row)
end

def piece_at_from_state(pieces, x, y)
  pieces.find { |p| p['x'] == x && p['y'] == y }
end

def board_size
  (DB.get_first_value('SELECT value FROM meta WHERE key = ?', ['board_size']) || '8').to_i
end

def reset_board
  DB.execute('DELETE FROM pieces')

  size = board_size
  size.times do |x|
    DB.execute('INSERT INTO pieces (name, symbol, color, x, y, move_count) VALUES (?, ?, ?, ?, ?, 0)', ['Pawn', 'P', 'white', x, size - 2])
    DB.execute('INSERT INTO pieces (name, symbol, color, x, y, move_count) VALUES (?, ?, ?, ?, ?, 0)', ['Pawn', 'p', 'black', x, 1])
  end

  # Default back rank layout if space allows (size >= 8): R N B Q K B N R
  if size >= 8
    back = [
      ['Rook', 0], ['Knight', 1], ['Bishop', 2], ['Queen', 3], ['King', 4], ['Bishop', 5], ['Knight', 6], ['Rook', 7]
    ]
    back.each do |name, x|
      next if x >= size
      DB.execute('INSERT INTO pieces (name, symbol, color, x, y, move_count) VALUES (?, ?, ?, ?, ?, 0)', [name, name[0], 'white', x, size - 1])
      DB.execute('INSERT INTO pieces (name, symbol, color, x, y, move_count) VALUES (?, ?, ?, ?, ?, 0)', [name, name[0].downcase, 'black', x, 0])
    end
  else
    # Fallback for small sizes: just place kings at center
    kx = size / 2
    DB.execute('INSERT INTO pieces (name, symbol, color, x, y, move_count) VALUES (?, ?, ?, ?, ?, 0)', ['King', 'K', 'white', kx, size - 1])
    DB.execute('INSERT INTO pieces (name, symbol, color, x, y, move_count) VALUES (?, ?, ?, ?, ?, 0)', ['King', 'k', 'black', kx, 0])
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

def patterns_for_piece(piece)
  MoveRulesStore.parsed_patterns_for(DB, name: piece['name'], color: piece['color'])
end

def taunting_piece?(piece)
  patterns_for_piece(piece).any? do |entry|
    pattern = entry['definition'] || {}
    pattern['taunt']
  end
end

def opponent_color(color)
  color == 'white' ? 'black' : 'white'
end

def piece_unmoved?(piece)
  piece['move_count'].to_i <= 0
end

def moves_from_definition(piece, pieces, pattern, size, for_attack: false)
  moves = []
  return moves unless pattern

  x = piece['x']
  y = piece['y']
  ray_limit = pattern['ray_limit'] || pattern['max_steps'] || size
  ray_limit = size if ray_limit.nil? || ray_limit.to_i <= 0 || ray_limit.to_s == 'infinite'

  Array(pattern['rays']).each do |dx, dy|
    1.upto(ray_limit) do |step|
      tx = x + dx.to_i * step
      ty = y + dy.to_i * step
      break if tx.negative? || ty.negative? || tx >= size || ty >= size

      occ = piece_at_from_state(pieces, tx, ty)
      if occ
        moves << { x: tx, y: ty, capture_id: occ['id'], kind: :normal } if occ['color'] != piece['color']
        break
      else
        moves << { x: tx, y: ty, capture_id: nil, kind: :normal }
      end
    end
  end

  Array(pattern['leaps']).each do |dx, dy|
    tx = x + dx.to_i
    ty = y + dy.to_i
    next if tx.negative? || ty.negative? || tx >= size || ty >= size

    occ = piece_at_from_state(pieces, tx, ty)
    moves << { x: tx, y: ty, capture_id: occ && occ['color'] != piece['color'] ? occ['id'] : nil, kind: :normal } if occ.nil? || occ['color'] != piece['color']
  end

  unless for_attack
    Array(pattern['move_only']).each do |dx, dy|
      tx = x + dx.to_i
      ty = y + dy.to_i
      next if tx.negative? || ty.negative? || tx >= size || ty >= size

      occ = piece_at_from_state(pieces, tx, ty)
      moves << { x: tx, y: ty, capture_id: nil, kind: :normal } unless occ
    end
  end

  Array(pattern['capture_only']).each do |dx, dy|
    tx = x + dx.to_i
    ty = y + dy.to_i
    next if tx.negative? || ty.negative? || tx >= size || ty >= size

    occ = piece_at_from_state(pieces, tx, ty)
    if for_attack
      next if occ && occ['color'] == piece['color']
      moves << { x: tx, y: ty, capture_id: occ && occ['color'] != piece['color'] ? occ['id'] : nil, kind: :normal }
    else
      moves << { x: tx, y: ty, capture_id: occ['id'], kind: :normal } if occ && occ['color'] != piece['color']
    end
  end

  moves
end

def dedup_moves(moves)
  seen = {}
  moves.each_with_object([]) do |move, acc|
    key = [move[:x], move[:y], move[:kind], move[:capture_id], move.fetch(:secondary, {})[:piece_id]]
    next if seen[key]

    seen[key] = true
    acc << move
  end
end

def allow_castling_for?(piece)
  piece['name'].to_s.downcase == 'king'
end

def castling_moves_for_piece(piece, pieces, size)
  return [] unless piece_unmoved?(piece)
  return [] unless size >= 5

  moves = []
  opponent = opponent_color(piece['color'])
  attacked = attacked_squares_for(pieces, opponent, size)
  return [] if attacked[[piece['x'], piece['y']]]

  rooks = pieces.select do |p|
    p['color'] == piece['color'] &&
      p['name'].to_s.downcase == 'rook' &&
      p['y'] == piece['y'] &&
      piece_unmoved?(p)
  end

  rooks.each do |rook|
    direction = rook['x'] < piece['x'] ? -1 : 1
    path_range = direction.negative? ? ((rook['x'] + 1)...piece['x']) : ((piece['x'] + 1)...rook['x'])
    next if path_range.to_a.empty?
    next unless path_range.all? { |px| piece_at_from_state(pieces, px, piece['y']).nil? }

    through_x = piece['x'] + direction
    target_x = piece['x'] + (2 * direction)
    next if target_x.negative? || target_x >= size

    next if attacked[[through_x, piece['y']]] || attacked[[target_x, piece['y']]]

    moves << {
      x: target_x,
      y: piece['y'],
      kind: :castle,
      capture_id: nil,
      secondary: { piece_id: rook['id'], x: target_x - direction, y: piece['y'] }
    }
  end

  moves
end

def generate_moves_for_piece(piece, pieces:, board_size:, for_attack: false)
  patterns = patterns_for_piece(piece)
  return [] if patterns.empty?

  moves = []

  patterns.each do |entry|
    definition = entry['definition'] || {}
    moves.concat(moves_from_definition(piece, pieces, definition, board_size, for_attack: for_attack))
    if !for_attack && piece_unmoved?(piece) && definition['first_move'].is_a?(Hash)
      moves.concat(moves_from_definition(piece, pieces, definition['first_move'], board_size, for_attack: for_attack))
    end
  end

  moves.concat(castling_moves_for_piece(piece, pieces, board_size)) if !for_attack && allow_castling_for?(piece)
  dedup_moves(moves)
end

def attacked_squares_for(pieces, attacker_color, size)
  attacked = {}
  pieces.select { |p| p['color'] == attacker_color }.each do |piece|
    generate_moves_for_piece(piece, pieces: pieces, board_size: size, for_attack: true).each do |move|
      attacked[[move[:x], move[:y]]] = true
    end
  end
  attacked
end

def king_in_check?(pieces, color, size = board_size)
  king_positions = pieces.select { |p| p['color'] == color && p['name'].to_s.downcase == 'king' }.map { |k| [k['x'], k['y']] }
  return false if king_positions.empty?

  attacked = attacked_squares_for(pieces, opponent_color(color), size)
  king_positions.any? { |pos| attacked[pos] }
end

def apply_move_to_pieces(pieces, piece, move)
  new_state = pieces.map { |p| p.dup }
  moving = new_state.find { |p| p['id'] == piece['id'] }
  return new_state unless moving

  if move[:capture_id]
    new_state.reject! { |p| p['id'] == move[:capture_id] }
  end

  moving['x'] = move[:x]
  moving['y'] = move[:y]
  moving['move_count'] = moving['move_count'].to_i + 1

  if move[:secondary]&.fetch(:piece_id, nil)
    secondary = new_state.find { |p| p['id'] == move[:secondary][:piece_id] }
    if secondary
      secondary['x'] = move[:secondary][:x]
      secondary['y'] = move[:secondary][:y]
      secondary['move_count'] = secondary['move_count'].to_i + 1
    end
  end

  new_state
end

def legal_moves_for_piece(piece, pieces, size)
  generate_moves_for_piece(piece, pieces: pieces, board_size: size).select do |move|
    updated = apply_move_to_pieces(pieces, piece, move)
    !king_in_check?(updated, piece['color'], size)
  end
end

def taunt_pieces_for_color(pieces, target_color)
  opponent = opponent_color(target_color)
  pieces.select { |p| p['color'] == opponent && taunting_piece?(p) }
end

def apply_taunt_filter(moves_by_piece, taunt_ids)
  return moves_by_piece, false if taunt_ids.empty?

  filtered = {}
  capture_available = false
  moves_by_piece.each do |pid, moves|
    taunt_moves = (moves || []).select { |m| taunt_ids.include?(m[:capture_id]) }
    filtered[pid] = taunt_moves
    capture_available ||= taunt_moves.any?
  end

  return moves_by_piece, false unless capture_available

  return filtered, true
end

def legal_moves_for_color(color, pieces, size)
  moves_by_piece = {}
  pieces.select { |p| p['color'] == color }.each do |piece|
    moves_by_piece[piece['id']] = legal_moves_for_piece(piece, pieces, size)
  end

  taunt_targets = taunt_pieces_for_color(pieces, color)
  taunt_ids = taunt_targets.map { |p| p['id'] }

  filtered_moves, taunt_forced = apply_taunt_filter(moves_by_piece, taunt_ids)
  [filtered_moves, taunt_forced]
end

def valid_moves_for_piece(piece, pieces = pieces_state, size = board_size)
  return [] unless piece

  moves_by_piece, = legal_moves_for_color(piece['color'], pieces, size)
  (moves_by_piece[piece['id']] || []).map { |move| [move[:x], move[:y]] }.uniq
end

before do
  MoveRulesStore.ensure_seeded!(DB)
end

# --- Routes ---
get '/' do
  redirect '/play/white'
end

get '/play/:color' do
  color = params[:color].to_s.downcase
  halt 404 unless PLAYER_COLORS.include?(color)

  @pieces = pieces_state
  @turn = get_turn
  @board_size = board_size
  @in_check = king_in_check?(@pieces, color, @board_size)
  @taunt_sources = taunt_pieces_for_color(@pieces, color)
  taunt_ids = @taunt_sources.map { |t| t['id'] }
  moves_by_color, taunt_forced = legal_moves_for_color(color, @pieces, @board_size)
  @taunt_forced = taunt_forced
  @rules_count = MoveRulesStore.pattern_count(DB)
  @player_color = color
  @board_orientation = color == 'black' ? :black : :white
  slim :index
end

post '/move' do
  from_x, from_y = params[:from].to_s.split(',').map(&:to_i)
  to_x, to_y = params[:to].to_s.split(',').map(&:to_i)
  player = normalize_player_color(params[:player])

  pieces = pieces_state
  piece = pieces.find { |p| p['x'] == from_x && p['y'] == from_y }
  halt 404 unless piece
  halt 403 unless piece['color'] == player
  halt 403 unless get_turn == player

  size = board_size
  moves_by_piece, = legal_moves_for_color(player, pieces, size)
  piece_moves = moves_by_piece[piece['id']] || []
  move = piece_moves.find { |m| m[:x] == to_x && m[:y] == to_y }
  halt 400 unless move

  DB.execute('DELETE FROM pieces WHERE id = ?', [move[:capture_id]]) if move[:capture_id]
  DB.execute('UPDATE pieces SET x = ?, y = ?, move_count = move_count + 1 WHERE id = ?', [to_x, to_y, piece['id']])

  if move[:secondary]&.fetch(:piece_id, nil)
    DB.execute('UPDATE pieces SET x = ?, y = ?, move_count = move_count + 1 WHERE id = ?', [move[:secondary][:x], move[:secondary][:y], move[:secondary][:piece_id]])
  end

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
  pieces = pieces_state
  p = pieces.find { |piece| piece['x'] == x && piece['y'] == y }
  halt 200, { moves: [] }.to_json unless p

  size = board_size
  moves_by_piece, taunt_forced = legal_moves_for_color(p['color'], pieces, size)
  taunt_sources = taunt_pieces_for_color(pieces, p['color'])
  taunt_ids = taunt_sources.map { |t| t['id'] }
  moves = (moves_by_piece[p['id']] || []).map { |m| [m[:x], m[:y]] }.uniq

  {
    moves: moves,
    in_check: king_in_check?(pieces, p['color'], size),
    taunted_by: taunt_sources.map { |t| { id: t['id'], name: t['name'], x: t['x'], y: t['y'] } },
    taunt_restricting: taunt_forced
  }.to_json
end

get '/state' do
  content_type :json
  { turn: get_turn, board_size: board_size }.to_json
end

# --- Move rules management ---
get '/move_rules' do
  content_type :json
  rules = MoveRulesStore.pattern_rows(DB).map do |row|
    row.merge('definition' => MoveRulesStore.parse_definition(row['definition']))
  end
  { count: rules.size, rules: rules }.to_json
end

post '/move_rules' do
  content_type :json
  name = params[:name].to_s.strip
  color = params[:color].to_s.strip
  color = nil if color.empty?
  definition_raw = params[:definition].to_s.strip

  halt 400, { error: 'name required' }.to_json if name.empty?

  definition =
    if !definition_raw.empty?
      begin
        JSON.parse(definition_raw)
      rescue JSON::ParserError => e
        halt 400, { error: "invalid definition JSON: #{e.message}" }.to_json
      end
    elsif params[:dx] && params[:dy]
      # Compatibility path: build a small pattern from vector inputs
      dx = params[:dx].to_i
      dy = params[:dy].to_i
      case params[:kind]
      when 'move_only'
        { 'move_only' => [[dx, dy]] }
      when 'capture_only'
        { 'capture_only' => [[dx, dy]] }
      else
        # Treat as a leap if max_steps == 1, otherwise as a ray
        steps = (params[:max_steps] || '1').to_i
        if steps > 1
          { 'rays' => [[dx, dy]], 'ray_limit' => steps }
        else
          { 'leaps' => [[dx, dy]] }
        end
      end
    end

  halt 400, { error: 'definition required (JSON)' }.to_json unless definition

  MoveRulesStore.upsert_pattern(DB, name: name, color: color, definition: definition)
  row = MoveRulesStore.pattern_rows(DB, name: name, color: color).first
  status 201
  row.merge('definition' => definition).to_json
end

post '/move_rules/seed_defaults' do
  MoveRulesStore.ensure_seeded!(DB)
  player = normalize_player_color(params[:player])
  redirect player_path(player)
end

post '/move_rules/reset_defaults' do
  MoveRulesStore.reset!(DB)
  player = normalize_player_color(params[:player])
  redirect player_path(player)
end

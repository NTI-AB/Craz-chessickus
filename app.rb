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
ensure_column(DB, 'pieces', 'effects', "effects TEXT NOT NULL DEFAULT '{}'")
DB.execute('UPDATE pieces SET move_count = 0 WHERE move_count IS NULL')
DB.execute('UPDATE pieces SET effects = "{}" WHERE effects IS NULL OR effects = ""')

MoveRulesStore.ensure_schema!(DB)
MOVE_RULES_VERSION = 2
PLAYER_COLORS = %w[white black].freeze
QUEEN_DIRECTIONS = [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [1, -1], [-1, 1], [-1, -1]].freeze
ADJACENT_DIRECTIONS = (-1..1).to_a.product((-1..1).to_a).reject { |dx, dy| dx.zero? && dy.zero? }.freeze
PIECE_VALUE_DEFAULTS = {
  'pawn' => 1,
  'knight' => 3,
  'bishop' => 3,
  'rook' => 5,
  'queen' => 9,
  'king' => 1000,
  'joker' => 3,
  'doomfist' => 6,
  'sniper' => 5,
  'sentinel' => 2,
  'assassin' => 7,
  'berserker' => 6,
  'catapult' => 4,
  'wraith' => 7,
  'juggernaut' => 8
}.freeze

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
ensure_meta_default('turn_counter_white', '0')
ensure_meta_default('turn_counter_black', '0')

MoveRulesStore.ensure_seeded!(DB)
ensure_move_rules_version!(MOVE_RULES_VERSION)

# --- Helper methods ---

def normalize_piece(row)
  return nil unless row

  row = row.transform_keys(&:to_s)
  row['x'] = row['x'].to_i
  row['y'] = row['y'].to_i
  row['move_count'] = (row['move_count'] || 0).to_i
  row['effects'] = parse_effects(row['effects'])
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

def piece_by_id(id)
  row = DB.get_first_row('SELECT * FROM pieces WHERE id = ?', [id])
  normalize_piece(row)
end

def board_size
  (DB.get_first_value('SELECT value FROM meta WHERE key = ?', ['board_size']) || '8').to_i
end

def reset_board
  DB.execute('DELETE FROM pieces')

  size = board_size
  size.times do |x|
    DB.execute('INSERT INTO pieces (name, symbol, color, x, y, move_count, effects) VALUES (?, ?, ?, ?, ?, 0, ?)', ['Pawn', 'P', 'white', x, size - 2, '{}'])
    DB.execute('INSERT INTO pieces (name, symbol, color, x, y, move_count, effects) VALUES (?, ?, ?, ?, ?, 0, ?)', ['Pawn', 'p', 'black', x, 1, '{}'])
  end

  # Default back rank layout if space allows (size >= 8): R N B Q K B N R
  if size >= 8
    back = [
      ['Rook', 0], ['Knight', 1], ['Bishop', 2], ['Queen', 3], ['King', 4], ['Bishop', 5], ['Knight', 6], ['Rook', 7]
    ]
    back.each do |name, x|
      next if x >= size
      DB.execute('INSERT INTO pieces (name, symbol, color, x, y, move_count, effects) VALUES (?, ?, ?, ?, ?, 0, ?)', [name, name[0], 'white', x, size - 1, '{}'])
      DB.execute('INSERT INTO pieces (name, symbol, color, x, y, move_count, effects) VALUES (?, ?, ?, ?, ?, 0, ?)', [name, name[0].downcase, 'black', x, 0, '{}'])
    end
  else
    # Fallback for small sizes: just place kings at center
    kx = size / 2
    DB.execute('INSERT INTO pieces (name, symbol, color, x, y, move_count, effects) VALUES (?, ?, ?, ?, ?, 0, ?)', ['King', 'K', 'white', kx, size - 1, '{}'])
    DB.execute('INSERT INTO pieces (name, symbol, color, x, y, move_count, effects) VALUES (?, ?, ?, ?, ?, 0, ?)', ['King', 'k', 'black', kx, 0, '{}'])
  end

  DB.execute('INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value', ['turn', 'white'])
  reset_turn_counters
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

def piece_name_key(piece)
  (piece['name'] || '').to_s.strip.downcase
end

def joker_piece?(piece)
  piece_name_key(piece) == 'joker'
end

def doomfist_piece?(piece)
  piece_name_key(piece) == 'doomfist'
end

def sniper_piece?(piece)
  piece_name_key(piece) == 'sniper'
end

def sentinel_piece?(piece)
  piece_name_key(piece) == 'sentinel'
end

def assassin_piece?(piece)
  piece_name_key(piece) == 'assassin'
end

def berserker_piece?(piece)
  piece_name_key(piece) == 'berserker'
end

def catapult_piece?(piece)
  piece_name_key(piece) == 'catapult'
end

def wraith_piece?(piece)
  piece_name_key(piece) == 'wraith'
end

def juggernaut_piece?(piece)
  piece_name_key(piece) == 'juggernaut'
end

def piece_value(piece)
  effects = piece_effects(piece)
  return effects['value_override'].to_i if effects['value_override']
  PIECE_VALUE_DEFAULTS[piece_name_key(piece)] || 5
end

def inside_board?(x, y, size)
  x >= 0 && y >= 0 && x < size && y < size
end

def turn_counter_key(color)
  "turn_counter_#{color}"
end

def turn_counter(color)
  key = turn_counter_key(color)
  (DB.get_first_value('SELECT value FROM meta WHERE key = ?', [key]) || '0').to_i
end

def increment_turn_counter(color)
  key = turn_counter_key(color)
  value = turn_counter(color) + 1
  DB.execute('INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value', [key, value.to_s])
end

def turn_counts_snapshot
  PLAYER_COLORS.to_h { |color| [color, turn_counter(color)] }
end

def reset_turn_counters
  PLAYER_COLORS.each do |color|
    key = turn_counter_key(color)
    DB.execute('INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value', [key, '0'])
  end
end

def patterns_for_piece(piece)
  MoveRulesStore.parsed_patterns_for(DB, name: piece['name'], color: piece['color'])
end

def parse_effects(raw)
  return {} if raw.nil? || raw.empty?
  JSON.parse(raw)
rescue JSON::ParserError
  {}
end

def piece_effects(piece)
  effects = piece['effects']
  return effects if effects.is_a?(Hash)
  parsed = parse_effects(effects)
  piece['effects'] = parsed
  parsed
end

def persist_piece_effects(piece_id, effects)
  payload = JSON.dump(effects || {})
  DB.execute('UPDATE pieces SET effects = ? WHERE id = ?', [payload, piece_id])
end

def update_piece_effect(piece, key, value)
  effects = piece_effects(piece).dup
  if value.nil?
    effects.delete(key)
  else
    effects[key] = value
  end
  persist_piece_effects(piece['id'], effects)
  piece['effects'] = effects
end

def piece_stunned?(piece, turn_counts = nil)
  info = piece_effects(piece)['stunned']
  return false unless info

  color = info['color'] || piece['color']
  until_turn = info['until_turn'].to_i
  turn_counts ||= {}
  current_turn = turn_counts[color] || turn_counter(color)
  current_turn < until_turn
end

def apply_stun_to_piece(piece, turns: 1)
  color = piece['color']
  info = {
    'color' => color,
    'until_turn' => turn_counter(color) + turns
  }
  update_piece_effect(piece, 'stunned', info)
end

def possession_info(piece)
  piece_effects(piece)['possession']
end

def possession_active?(piece, turn_counts = nil)
  info = possession_info(piece)
  return false unless info

  controller = info['controller'] || piece['color']
  expires_on = info['expires_on_turn'].to_i
  turn_counts ||= {}
  current_turn = turn_counts[controller] || turn_counter(controller)
  current_turn < expires_on
end

def apply_possession(piece, controller_color, duration: 3)
  original_color = piece['color']
  info = {
    'controller' => controller_color,
    'original_color' => original_color,
    'expires_on_turn' => turn_counter(controller_color) + duration
  }
  DB.execute('UPDATE pieces SET color = ? WHERE id = ?', [controller_color, piece['id']])
  piece['color'] = controller_color
  update_piece_effect(piece, 'possession', info)
end

def clear_possession(piece)
  info = possession_info(piece)
  return unless info

  original = info['original_color']
  if original && piece['color'] != original
    DB.execute('UPDATE pieces SET color = ? WHERE id = ?', [original, piece['id']])
    piece['color'] = original
  end
  update_piece_effect(piece, 'possession', nil)
end

def cleanup_piece_effects(turn_counts = nil)
  turn_counts ||= PLAYER_COLORS.to_h { |color| [color, turn_counter(color)] }
  pieces_state.each do |piece|
    effects = piece_effects(piece)
    stunned = effects['stunned']
    if stunned
      color = stunned['color'] || piece['color']
      until_turn = stunned['until_turn'].to_i
      current = turn_counts[color] || turn_counter(color)
      update_piece_effect(piece, 'stunned', nil) if current >= until_turn
    end

    info = possession_info(piece)
    next unless info

    controller = info['controller']
    expires_on = info['expires_on_turn'].to_i
    current = turn_counts[controller] || turn_counter(controller)
    next if current < expires_on

    clear_possession(piece)
  end
end

def possession_blocks_capture?(piece, target)
  info = possession_info(piece)
  return false unless info

  original = info['original_color']
  return false unless original
  piece_name_key(target) == 'king' && target['color'] == original
end

def capture_allowed?(piece, target, protected_ids)
  return false unless target
  return false if target['color'] == piece['color']
  return false if protected_ids[target['id']]
  return false if possession_blocks_capture?(piece, target)
  true
end

def taunting_piece?(piece)
  patterns_for_piece(piece).any? do |entry|
    pattern = entry['definition'] || {}
    pattern['taunt']
  end
end

def protector_piece?(piece)
  !protection_rules_for(piece).nil?
end

def default_protection_rules(piece)
  {
    directions: [[0, 1], [0, -1]],
    mode: :line,
    max_steps: nil
  }
end

def normalize_protection_rules(raw_rules, piece)
  return default_protection_rules(piece) if raw_rules == true

  if raw_rules.is_a?(Hash)
    directions = raw_rules['directions'] || raw_rules[:directions]
    directions = Array(directions).map { |dx, dy| [dx.to_i, dy.to_i] }
    directions = default_protection_rules(piece)[:directions] if directions.empty?
    mode = raw_rules['mode'] || raw_rules[:mode]
    mode = mode&.to_sym || :line
    max_steps = raw_rules['max_steps'] || raw_rules[:max_steps]
    {
      directions: directions,
      mode: mode,
      max_steps: max_steps&.to_i
    }
  else
    default_protection_rules(piece)
  end
end

def protection_rules_for(piece)
  patterns_for_piece(piece).each do |entry|
    protect = (entry['definition'] || {})['protect']
    next unless protect
    return normalize_protection_rules(protect, piece)
  end
  nil
end

def opponent_color(color)
  color == 'white' ? 'black' : 'white'
end

def piece_unmoved?(piece)
  piece['move_count'].to_i <= 0
end

def protected_piece_ids(pieces, size = board_size)
  protected = {}
  pieces.each do |piece|
    rules = protection_rules_for(piece)
    next unless rules

    directions = Array(rules[:directions])
    directions.each do |dx, dy|
      steps = 0
      tx = piece['x'] + dx.to_i
      ty = piece['y'] + dy.to_i

      while inside_board?(tx, ty, size)
        occ = piece_at_from_state(pieces, tx, ty)
        if occ
          break unless occ['color'] == piece['color']
          protected[occ['id']] = true
          break unless rules[:mode] == :chain
        end

        steps += 1
        break if rules[:max_steps] && steps >= rules[:max_steps]
        tx += dx.to_i
        ty += dy.to_i
      end
    end
  end
  protected
end

def moves_from_definition(piece, pieces, pattern, size, for_attack: false, protected_ids: {})
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
        if capture_allowed?(piece, occ, protected_ids)
          moves << { x: tx, y: ty, capture_id: occ['id'], kind: :normal }
        end
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
    if occ.nil?
      moves << { x: tx, y: ty, capture_id: nil, kind: :normal }
    elsif capture_allowed?(piece, occ, protected_ids)
      moves << { x: tx, y: ty, capture_id: occ['id'], kind: :normal }
    end
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
      if occ && capture_allowed?(piece, occ, protected_ids)
        moves << { x: tx, y: ty, capture_id: occ['id'], kind: :normal }
      elsif occ.nil?
        moves << { x: tx, y: ty, capture_id: nil, kind: :normal }
      end
    else
      moves << { x: tx, y: ty, capture_id: occ['id'], kind: :normal } if occ && capture_allowed?(piece, occ, protected_ids)
    end
  end

  moves
end

def doomfist_special_moves(piece, pieces, size, for_attack:, protected_ids:)
  return [] unless doomfist_piece?(piece)

  moves = []
  size.times do |tx|
    size.times do |ty|
      next if tx == piece['x'] && ty == piece['y']
      dx = tx - piece['x']
      dy = ty - piece['y']
      next if dx.zero? || dy.zero?

      occ = piece_at_from_state(pieces, tx, ty)
      if occ.nil?
        moves << { x: tx, y: ty, capture_id: nil, kind: :normal } unless for_attack
      elsif capture_allowed?(piece, occ, protected_ids) && piece_name_key(occ) != 'king'
        moves << { x: tx, y: ty, capture_id: occ['id'], kind: :normal }
      end

      if for_attack && (occ.nil? || occ['color'] != piece['color'])
        moves << { x: tx, y: ty, capture_id: occ&.dig('id'), kind: :normal }
      end
    end
  end

  dedup_moves(moves)
end

def sniper_special_moves(piece, pieces, size, protected_ids:)
  return [] unless sniper_piece?(piece)

  moves = []
  QUEEN_DIRECTIONS.each do |dx, dy|
    tx = piece['x'] + dx
    ty = piece['y'] + dy
    while inside_board?(tx, ty, size)
      occ = piece_at_from_state(pieces, tx, ty)
      if occ
        break unless capture_allowed?(piece, occ, protected_ids)
        moves << { x: tx, y: ty, capture_id: occ['id'], kind: :stationary_capture }
        break
      end
      tx += dx
      ty += dy
    end
  end
  moves
end

def assassin_jump_captures(piece, pieces, size, protected_ids:)
  return [] unless assassin_piece?(piece)

  moves = []
  QUEEN_DIRECTIONS.each do |dx, dy|
    adj_x = piece['x'] + dx
    adj_y = piece['y'] + dy
    next unless inside_board?(adj_x, adj_y, size)

    blocker = piece_at_from_state(pieces, adj_x, adj_y)
    next unless blocker
    next if protected_ids[blocker['id']]

    tx = adj_x + dx
    ty = adj_y + dy
    while inside_board?(tx, ty, size)
      occ = piece_at_from_state(pieces, tx, ty)
      if occ
        moves << { x: tx, y: ty, capture_id: occ['id'], kind: :jump_capture } if capture_allowed?(piece, occ, protected_ids)
        break
      end
      tx += dx
      ty += dy
    end
  end

  dedup_moves(moves)
end

def catapult_launch_moves(piece, pieces, size, protected_ids:)
  return [] unless catapult_piece?(piece)

  moves = []
  adjacent_allies = ADJACENT_DIRECTIONS.filter_map do |dx, dy|
    tx = piece['x'] + dx
    ty = piece['y'] + dy
    next unless inside_board?(tx, ty, size)
    target = piece_at_from_state(pieces, tx, ty)
    target if target && target['color'] == piece['color']
  end

  return moves if adjacent_allies.empty?

  directions = QUEEN_DIRECTIONS
  adjacent_allies.each do |ally|
    directions.each do |dx, dy|
      tx = ally['x']
      ty = ally['y']
      landing_x = nil
      landing_y = nil
      capture_id = nil

      loop do
        tx += dx
        ty += dy
        break unless inside_board?(tx, ty, size)

        occ = piece_at_from_state(pieces, tx, ty)
        if occ
          if capture_allowed?(ally, occ, protected_ids)
            capture_id = occ['id']
            landing_x = tx
            landing_y = ty
          else
            landing_x = nil
            landing_y = nil
          end
          break
        else
          landing_x = tx
          landing_y = ty
        end
      end

      next unless landing_x

      moves << {
        x: landing_x,
        y: landing_y,
        kind: :launch,
        capture_id: capture_id,
        secondary: { piece_id: ally['id'], x: landing_x, y: landing_y, origin_piece: piece['id'] }
      }
    end
  end

  dedup_moves(moves)
end

def wraith_possession_moves(piece, pieces, size, protected_ids:)
  return [] unless wraith_piece?(piece)

  moves = []
  QUEEN_DIRECTIONS.each do |dx, dy|
    tx = piece['x'] + dx
    ty = piece['y'] + dy
    steps = 0
    while inside_board?(tx, ty, size) && steps < 3
      occ = piece_at_from_state(pieces, tx, ty)
      if occ
        break if occ['color'] == piece['color']
        break if piece_name_key(occ) == 'king'
        break if wraith_piece?(occ)
        break if protected_ids[occ['id']]
        moves << {
          x: occ['x'],
          y: occ['y'],
          kind: :possession,
          target_piece_id: occ['id'],
          possession: { duration: 3 }
        }
        break
      end
      tx += dx
      ty += dy
      steps += 1
    end
  end
  moves
end

def juggernaut_moves(piece, pieces, size, protected_ids:)
  return [] unless juggernaut_piece?(piece)

  data = []
  QUEEN_DIRECTIONS.each do |dx, dy|
    tx = piece['x']
    ty = piece['y']
    path = []
    empty_count = 0

    loop do
      tx += dx
      ty += dy
      break unless inside_board?(tx, ty, size)

      occ = piece_at_from_state(pieces, tx, ty)
      path << { x: tx, y: ty, occ: occ }
      if occ.nil?
        empty_count += 1
        next
      end

      break
    end

    data << { path: path, empty_count: empty_count }
  end

  max_empty = data.map { |entry| entry[:empty_count] }.max
  return [] if max_empty.nil?

  moves = []
  data.each do |entry|
    next unless entry[:empty_count] == max_empty
    path = entry[:path]
    next if path.empty?

    landing = path.last
    occ = landing[:occ]

    if occ && occ['color'] == piece['color']
      landing = path.reverse.find { |sq| sq[:occ].nil? }
      next unless landing
      occ = nil
    end

    if occ && capture_allowed?(piece, occ, protected_ids)
      next if piece_name_key(occ) == 'king'
      moves << { x: landing[:x], y: landing[:y], capture_id: occ['id'], kind: :normal }
    elsif occ.nil?
      moves << { x: landing[:x], y: landing[:y], capture_id: nil, kind: :normal }
    end
  end

  dedup_moves(moves)
end

def berserker_chain_sequences(piece, pieces, size, move, protected_ids, captured_ids: [], path: [], value_limit: nil)
  target = pieces.find { |p| p['id'] == move[:capture_id] }
  return [] unless target

  capture_value = piece_value(target)
  return [] if value_limit && capture_value > value_limit

  new_pieces = apply_move_to_pieces(pieces, piece, move)
  new_captured_ids = captured_ids + [target['id']]
  new_path = path + [[move[:x], move[:y]]]
  next_piece = new_pieces.find { |p| p['id'] == piece['id'] }
  return [] unless next_piece

  next_protected = protected_piece_ids(new_pieces, size)
  next_moves = pattern_moves_for_piece(next_piece, new_pieces, size, for_attack: false, protected_ids: next_protected)
  capture_moves = next_moves.select { |m| m[:capture_id] }

  allowed = capture_moves.select do |candidate|
    captured_piece = new_pieces.find { |p| p['id'] == candidate[:capture_id] }
    captured_piece && piece_value(captured_piece) <= capture_value
  end

  if allowed.empty?
    [{
      x: move[:x],
      y: move[:y],
      kind: :berserk,
      capture_id: target['id'],
      capture_sequence: new_captured_ids,
      path: new_path,
      dies: true
    }]
  else
    allowed.flat_map do |candidate|
      berserker_chain_sequences(next_piece, new_pieces, size, candidate, next_protected,
                                captured_ids: new_captured_ids,
                                path: new_path,
                                value_limit: capture_value)
    end
  end
end

def berserker_chain_moves(piece, pieces, size, base_moves, protected_ids)
  capture_moves = base_moves.select { |m| m[:capture_id] }
  return base_moves if capture_moves.empty?

  capture_moves.flat_map do |move|
    berserker_chain_sequences(piece, pieces, size, move, protected_ids)
  end
end

def dedup_moves(moves)
  seen = {}
  moves.each_with_object([]) do |move, acc|
    key = [move[:x], move[:y], move[:kind], move[:capture_id], move.fetch(:secondary, {})[:piece_id], Array(move[:capture_sequence])]
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
  attacked = attacked_squares_for(pieces, opponent, size, turn_counts: turn_counts_snapshot)
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

def pattern_moves_for_piece(piece, pieces, size, for_attack:, protected_ids:)
  patterns = patterns_for_piece(piece)
  return [] if patterns.empty?

  moves = []
  patterns.each do |entry|
    definition = entry['definition'] || {}
    moves.concat(moves_from_definition(piece, pieces, definition, size, for_attack: for_attack, protected_ids: protected_ids))
    if !for_attack && piece_unmoved?(piece) && definition['first_move'].is_a?(Hash)
      moves.concat(moves_from_definition(piece, pieces, definition['first_move'], size, for_attack: for_attack, protected_ids: protected_ids))
    end
  end

  moves
end

def generate_moves_for_piece(piece, pieces:, board_size:, for_attack: false, protected_ids: {})
  base_moves = pattern_moves_for_piece(piece, pieces, board_size, for_attack: for_attack, protected_ids: protected_ids) || []
  moves = base_moves.dup
  if berserker_piece?(piece) && !for_attack
    moves = berserker_chain_moves(piece, pieces, board_size, base_moves, protected_ids)
  end

  moves.concat(doomfist_special_moves(piece, pieces, board_size, for_attack: for_attack, protected_ids: protected_ids)) if doomfist_piece?(piece)
  moves.concat(sniper_special_moves(piece, pieces, board_size, protected_ids: protected_ids)) if sniper_piece?(piece)
  moves.concat(assassin_jump_captures(piece, pieces, board_size, protected_ids: protected_ids)) if assassin_piece?(piece)
  moves.concat(catapult_launch_moves(piece, pieces, board_size, protected_ids: protected_ids)) if catapult_piece?(piece)
  moves.concat(wraith_possession_moves(piece, pieces, board_size, protected_ids: protected_ids)) if wraith_piece?(piece) && !for_attack
  moves.concat(juggernaut_moves(piece, pieces, board_size, protected_ids: protected_ids)) if juggernaut_piece?(piece)

  moves.concat(castling_moves_for_piece(piece, pieces, board_size)) if !for_attack && allow_castling_for?(piece)
  dedup_moves(moves)
end

def attacked_squares_for(pieces, attacker_color, size, protected_ids: protected_piece_ids(pieces, size), turn_counts: turn_counts_snapshot)
  attacked = {}
  pieces.select { |p| p['color'] == attacker_color }.each do |piece|
    next if piece_stunned?(piece, turn_counts)
    generate_moves_for_piece(piece, pieces: pieces, board_size: size, for_attack: true, protected_ids: protected_ids).each do |move|
      attacked[[move[:x], move[:y]]] = true
    end
  end
  attacked
end

def king_in_check?(pieces, color, size = board_size, turn_counts: turn_counts_snapshot)
  king_positions = pieces.select { |p| p['color'] == color && p['name'].to_s.downcase == 'king' }.map { |k| [k['x'], k['y']] }
  return false if king_positions.empty?

  attacked = attacked_squares_for(pieces, opponent_color(color), size, turn_counts: turn_counts)
  king_positions.any? { |pos| attacked[pos] }
end

def apply_move_to_pieces(pieces, piece, move)
  new_state = pieces.map { |p| p.dup }
  moving = new_state.find { |p| p['id'] == piece['id'] }
  return new_state unless moving

  capture_ids = Array(move[:capture_sequence]).compact
  capture_ids = if capture_ids.empty?
                  move[:capture_id] ? [move[:capture_id]] : []
                else
                  capture_ids
                end
  capture_ids.each do |cid|
    new_state.reject! { |p| p['id'] == cid }
  end

  stationary_kind = %i[stationary_capture possession launch].include?(move[:kind])
  unless stationary_kind || move[:kind] == :berserk
    moving['x'] = move[:x]
    moving['y'] = move[:y]
  end
  moving['move_count'] = moving['move_count'].to_i + 1

  if move[:secondary]&.fetch(:piece_id, nil)
    secondary = new_state.find { |p| p['id'] == move[:secondary][:piece_id] }
    if secondary
      secondary['x'] = move[:secondary][:x]
      secondary['y'] = move[:secondary][:y]
      secondary['move_count'] = secondary['move_count'].to_i + 1
    end
  end

  case move[:kind]
  when :launch
    # Catapult stays in place; movement applied above skipped adjusting coordinates.
  when :stationary_capture
    # Piece remains in place; captured piece already removed.
  when :possession
    target = new_state.find { |p| p['id'] == move[:target_piece_id] }
    if target
      original_color = target['color']
      target['color'] = moving['color']
      effects = target['effects'].dup
      effects['possession'] = { 'controller' => moving['color'], 'original_color' => original_color }
      target['effects'] = effects
    end
  when :berserk
    new_state.reject! { |p| p['id'] == moving['id'] }
  end

  new_state
end

def legal_moves_for_piece(piece, pieces, size, protected_ids, turn_counts)
  return [] if piece_stunned?(piece, turn_counts)

  generate_moves_for_piece(piece, pieces: pieces, board_size: size, protected_ids: protected_ids).select do |move|
    updated = apply_move_to_pieces(pieces, piece, move)
    !king_in_check?(updated, piece['color'], size, turn_counts: turn_counts)
  end
end

def taunt_pieces_for_color(pieces, target_color, protected_ids = protected_piece_ids(pieces, board_size), turn_counts: turn_counts_snapshot)
  opponent = opponent_color(target_color)
  pieces.select do |p|
    p['color'] == opponent &&
      taunting_piece?(p) &&
      !protected_ids[p['id']] &&
      !piece_stunned?(p, turn_counts)
  end
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
  protected_ids = protected_piece_ids(pieces, size)
  turn_counts = turn_counts_snapshot
  moves_by_piece = {}
  pieces.select { |p| p['color'] == color }.each do |piece|
    moves_by_piece[piece['id']] = legal_moves_for_piece(piece, pieces, size, protected_ids, turn_counts)
  end

  taunt_targets = taunt_pieces_for_color(pieces, color, protected_ids, turn_counts: turn_counts)
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
  cleanup_piece_effects
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
  turn_counts = turn_counts_snapshot
  @in_check = king_in_check?(@pieces, color, @board_size, turn_counts: turn_counts)
  protected_ids = protected_piece_ids(@pieces, @board_size)
  @taunt_sources = taunt_pieces_for_color(@pieces, color, protected_ids, turn_counts: turn_counts)
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

  capture_ids = Array(move[:capture_sequence]).compact
  capture_ids = if capture_ids.empty?
                  move[:capture_id] ? [move[:capture_id]] : []
                else
                  capture_ids
                end
  capture_ids.uniq.each do |cid|
    DB.execute('DELETE FROM pieces WHERE id = ?', [cid])
  end

  stationary_kind = %i[stationary_capture launch possession].include?(move[:kind])
  new_x = stationary_kind ? piece['x'] : to_x
  new_y = stationary_kind ? piece['y'] : to_y

  unless move[:kind] == :berserk
    DB.execute('UPDATE pieces SET x = ?, y = ?, move_count = move_count + 1 WHERE id = ?', [new_x, new_y, piece['id']])
  else
    DB.execute('DELETE FROM pieces WHERE id = ?', [piece['id']])
  end

  if move[:secondary]&.fetch(:piece_id, nil)
    DB.execute('UPDATE pieces SET x = ?, y = ?, move_count = move_count + 1 WHERE id = ?', [move[:secondary][:x], move[:secondary][:y], move[:secondary][:piece_id]])
  end

  case move[:kind]
  when :possession
    target_piece = pieces.find { |p| p['id'] == move[:target_piece_id] }
    apply_possession(target_piece, piece['color'], duration: move.dig(:possession, :duration) || 3) if target_piece
  end

  moved_piece = move[:kind] == :berserk ? nil : piece_by_id(piece['id'])
  if moved_piece && doomfist_piece?(piece) && capture_ids.any?
    apply_stun_to_piece(moved_piece)
  end

  increment_turn_counter(player)
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
  protected_ids = protected_piece_ids(pieces, size)
  turn_counts = turn_counts_snapshot
  moves_by_piece, taunt_forced = legal_moves_for_color(p['color'], pieces, size)
  taunt_sources = taunt_pieces_for_color(pieces, p['color'], protected_ids, turn_counts: turn_counts)
  taunt_ids = taunt_sources.map { |t| t['id'] }
  moves = (moves_by_piece[p['id']] || []).map { |m| [m[:x], m[:y]] }.uniq

  {
    moves: moves,
    in_check: king_in_check?(pieces, p['color'], size, turn_counts: turn_counts),
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

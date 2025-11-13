module MoveRulesStore
  module_function

  def ensure_schema!(db)
    db.execute <<~SQL
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

    db.execute <<~SQL
      CREATE UNIQUE INDEX IF NOT EXISTS idx_move_rules_uniqueness
      ON move_rules(name, IFNULL(color, ''), dx, dy, max_steps, kind);
    SQL
  end

  def seed_defaults(db)
    # King: 8 directions, 1 step
    [-1, 0, 1].each do |dx|
      [-1, 0, 1].each do |dy|
        next if dx.zero? && dy.zero?

        db.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)',
                   ['King', nil, dx, dy, 1, 'normal'])
      end
    end

    # Pawn forward and capture (color-specific)
    db.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)',
               ['Pawn', 'white', 0, -1, 1, 'move_only'])
    db.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)',
               ['Pawn', 'white', -1, -1, 1, 'capture_only'])
    db.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)',
               ['Pawn', 'white', 1, -1, 1, 'capture_only'])
    db.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)',
               ['Pawn', 'black', 0, 1, 1, 'move_only'])
    db.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)',
               ['Pawn', 'black', -1, 1, 1, 'capture_only'])
    db.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)',
               ['Pawn', 'black', 1, 1, 1, 'capture_only'])

    # Rook: orthogonal sliding
    [[1, 0], [-1, 0], [0, 1], [0, -1]].each do |dx, dy|
      db.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)',
                 ['Rook', nil, dx, dy, 99, 'normal'])
    end

    # Bishop: diagonal sliding
    [[1, 1], [1, -1], [-1, 1], [-1, -1]].each do |dx, dy|
      db.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)',
                 ['Bishop', nil, dx, dy, 99, 'normal'])
    end

    # Queen: rook + bishop sliding
    [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [1, -1], [-1, 1], [-1, -1]].each do |dx, dy|
      db.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)',
                 ['Queen', nil, dx, dy, 99, 'normal'])
    end

    # Knight: L-shapes
    [[1, 2], [2, 1], [2, -1], [1, -2], [-1, -2], [-2, -1], [-2, 1], [-1, 2]].each do |dx, dy|
      db.execute('INSERT OR IGNORE INTO move_rules (name, color, dx, dy, max_steps, kind) VALUES (?, ?, ?, ?, ?, ?)',
                 ['Knight', nil, dx, dy, 1, 'normal'])
    end
  end

  def ensure_seeded!(db)
    count = db.get_first_value('SELECT COUNT(*) FROM move_rules').to_i
    seed_defaults(db) if count.zero?
  end

  def reset!(db)
    db.execute('DELETE FROM move_rules')
    seed_defaults(db)
  end
end

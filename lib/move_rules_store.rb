require 'json'

module MoveRulesStore
  DEFAULT_PATTERNS = [
    {
      name: 'King',
      color: nil,
      definition: {
        rays: [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [1, -1], [-1, 1], [-1, -1]],
        ray_limit: 1
      }
    },
    {
      name: 'Queen',
      color: nil,
      definition: {
        rays: [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [1, -1], [-1, 1], [-1, -1]],
        ray_limit: nil # infinite
      }
    },
    {
      name: 'Rook',
      color: nil,
      definition: {
        rays: [[1, 0], [-1, 0], [0, 1], [0, -1]],
        ray_limit: nil # infinite
      }
    },
    {
      name: 'Bishop',
      color: nil,
      definition: {
        rays: [[1, 1], [1, -1], [-1, 1], [-1, -1]],
        ray_limit: nil # infinite
      }
    },
    {
      name: 'Knight',
      color: nil,
      definition: {
        leaps: [[1, 2], [2, 1], [2, -1], [1, -2], [-1, -2], [-2, -1], [-2, 1], [-1, 2]]
      }
    },
    {
      name: 'Pawn',
      color: 'white',
      definition: {
        move_only: [[0, -1]],
        capture_only: [[-1, -1], [1, -1]],
        first_move: {
          rays: [[0, -1]],
          ray_limit: 2
        }
      }
    },
    {
      name: 'Pawn',
      color: 'black',
      definition: {
        move_only: [[0, 1]],
        capture_only: [[-1, 1], [1, 1]],
        first_move: {
          rays: [[0, 1]],
          ray_limit: 2
        }
      }
    }
  ].freeze

  module_function

  def ensure_schema!(db)
    # Legacy table kept for compatibility; the new engine reads from move_patterns.
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

    db.execute <<~SQL
      CREATE TABLE IF NOT EXISTS move_patterns (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        color TEXT,
        definition TEXT NOT NULL
      );
    SQL

    db.execute <<~SQL
      CREATE UNIQUE INDEX IF NOT EXISTS idx_move_patterns_uniqueness
      ON move_patterns(name, IFNULL(color, ''));
    SQL
  end

  def upsert_pattern(db, name:, color: nil, definition:)
    definition_json = JSON.dump(definition)
    db.execute(<<~SQL, [name, color, definition_json])
      INSERT INTO move_patterns (name, color, definition)
      VALUES (?, ?, ?)
      ON CONFLICT(name, IFNULL(color, ''))
      DO UPDATE SET definition = excluded.definition
    SQL
  end

  def pattern_rows(db, name: nil, color: nil)
    if name
      db.execute('SELECT * FROM move_patterns WHERE name = ? AND (color IS NULL OR color = ?) ORDER BY color IS NOT NULL DESC', [name, color])
    else
      db.execute('SELECT * FROM move_patterns ORDER BY name, color')
    end
  end

  def parsed_patterns_for(db, name:, color:)
    pattern_rows(db, name: name, color: color).map do |row|
      definition = parse_definition(row['definition'])
      { 'name' => row['name'], 'color' => row['color'], 'definition' => definition }
    end
  end

  def parse_definition(definition_json)
    JSON.parse(definition_json)
  rescue JSON::ParserError
    {}
  end

  def seed_defaults(db)
    DEFAULT_PATTERNS.each do |pattern|
      upsert_pattern(db,
                     name: pattern[:name],
                     color: pattern[:color],
                     definition: pattern[:definition])
    end
  end

  def ensure_seeded!(db)
    count = db.get_first_value('SELECT COUNT(*) FROM move_patterns').to_i
    seed_defaults(db) if count.zero?
  end

  def reset!(db)
    db.execute('DELETE FROM move_patterns')
    seed_defaults(db)
  end

  def pattern_count(db)
    db.get_first_value('SELECT COUNT(*) FROM move_patterns').to_i
  end
end

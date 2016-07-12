require 'sqlite3'
require_relative 'populator'

def get_db_path
  Dir.glob('*.sqlite').first # Get DB filepath from current folder
end

db = SQLite3::Database.open(get_db_path)

Populator.new(db).populate

p 'Done!'
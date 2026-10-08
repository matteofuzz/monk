# Routes that read and write the app's own tables (monk add postgres).
#
# monk:example postgres-model -- a table, a model, and the routes using it.
# # Uncomment, then move each part where its comment says.
#
# # 1. The table, in a migration: db/migrate/<timestamp>_create_notes.up.sql
# #    (and .down.sql with DROP TABLE notes;), then bin/setup_db.
# #
# #    CREATE TABLE notes (id BIGSERIAL PRIMARY KEY, body TEXT NOT NULL);
#
# # 2. The model, in app/models/note.rb. Rows are plain Hashes, not objects.
# class Note < Monk::Persistence::Pg::Model
#   self.db_name = :primary
#   self.table_name = "notes"
# end
#
# # 3. The routes, here. params come from the query string or a JSON body.
# class App
#   get("/notes") { json(notes: Note.where({}, order: :id, limit: 20)) }
#   post("/notes") { json(note: Note.create(body: params[:body].to_s)) }
# end
# monk:end

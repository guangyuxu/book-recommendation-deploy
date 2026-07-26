-- Runs once, on first Postgres init, against the default database (POSTGRES_DB = "book").
--
-- Three logical stores share this one Postgres instance:
--   * db "book",  schema "accounts"   -> accounts service (IdP + family/child CRUD)
--   * db "book",  schema "book_agent" -> agent domain tables (recommendations/books)
--   * db "langgraph"                  -> LangGraph Server's own checkpointer/store (self-migrates)

-- Create the LangGraph Server database (cluster-level; guarded so a re-run is harmless).
SELECT 'CREATE DATABASE langgraph'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'langgraph')\gexec

-- Schemas live inside the "book" database (the connection this script already runs in).
\connect book
CREATE SCHEMA IF NOT EXISTS accounts;
CREATE SCHEMA IF NOT EXISTS book_agent;

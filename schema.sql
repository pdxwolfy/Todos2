DROP TABLE todos;
DROP TABLE lists;

CREATE TABLE lists (
    id   SERIAL  PRIMARY KEY,
    name VARCHAR NOT NULL UNIQUE
);

CREATE TABLE todos (
    id        SERIAL  PRIMARY KEY,
    name      TEXT    NOT NULL,
    completed BOOLEAN NOT NULL DEFAULT false,
    list_id   INTEGER NOT NULL REFERENCES lists (id)
);

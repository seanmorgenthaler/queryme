DROP VIEW  IF EXISTS v_overdue_loans, v_item_availability, v_catalog CASCADE;
DROP TABLE IF EXISTS loan, copy, library_user, video, audio, periodical, book, item CASCADE;

-- ---------- Supertype ----------
CREATE TABLE item (
    item_id           INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bib_num           INTEGER UNIQUE,              -- source catalog record number (Seattle Public Library BibNum)
    title             VARCHAR(255) NOT NULL,
    publisher         VARCHAR(150),
    media_type        VARCHAR(12)  NOT NULL
                      CHECK (media_type IN ('book','periodical','audio','video')),
    publishing_date   DATE,
    dewey_decimal_id  VARCHAR(12)
                      CHECK (dewey_decimal_id ~ '^[0-9]{3}(\.[0-9]+)?$'),
    CONSTRAINT uq_item_id_media_type UNIQUE (item_id, media_type)   -- target of subtype FKs
);

-- ---------- Subtypes ----------
CREATE TABLE book (
    item_id     INTEGER PRIMARY KEY,
    media_type  VARCHAR(12) NOT NULL DEFAULT 'book' CHECK (media_type = 'book'),
    author      VARCHAR(150),                    -- NULL for anonymous/corporate works
    isbn        VARCHAR(17)  UNIQUE,             -- NULL for older/uncatalogued books
    FOREIGN KEY (item_id, media_type) REFERENCES item (item_id, media_type) ON DELETE CASCADE
);

CREATE TABLE periodical (
    item_id     INTEGER PRIMARY KEY,
    media_type  VARCHAR(12) NOT NULL DEFAULT 'periodical' CHECK (media_type = 'periodical'),
    author      VARCHAR(150),
    issn        VARCHAR(9)  CHECK (issn ~ '^[0-9]{4}-[0-9]{3}[0-9X]$'),   -- not in the SPL export
    volume      INTEGER     CHECK (volume > 0),
    UNIQUE (issn, volume),                       -- one row per issue of a series
    FOREIGN KEY (item_id, media_type) REFERENCES item (item_id, media_type) ON DELETE CASCADE
);

CREATE TABLE audio (
    item_id           INTEGER PRIMARY KEY,
    media_type        VARCHAR(12) NOT NULL DEFAULT 'audio' CHECK (media_type = 'audio'),
    author            VARCHAR(150),
    duration_minutes  INTEGER CHECK (duration_minutes > 0),          -- not in the SPL export
    FOREIGN KEY (item_id, media_type) REFERENCES item (item_id, media_type) ON DELETE CASCADE
);

CREATE TABLE video (
    item_id           INTEGER PRIMARY KEY,
    media_type        VARCHAR(12) NOT NULL DEFAULT 'video' CHECK (media_type = 'video'),
    duration_minutes  INTEGER CHECK (duration_minutes > 0),          -- not in the SPL export
    region_code       VARCHAR(4),
    rating            VARCHAR(6) CHECK (rating IN ('G','PG','PG-13','R','NR')),
    FOREIGN KEY (item_id, media_type) REFERENCES item (item_id, media_type) ON DELETE CASCADE
);

CREATE TABLE library_user (
    user_id  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name     VARCHAR(120) NOT NULL,
    email    VARCHAR(255) NOT NULL UNIQUE
             CHECK (email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
    role     VARCHAR(12) NOT NULL DEFAULT 'patron'
             CHECK (role IN ('patron','staff','librarian','admin')),
    status   VARCHAR(12) NOT NULL DEFAULT 'active'
             CHECK (status IN ('active','suspended','expired'))
);

CREATE TABLE copy (
    copy_id  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_id  INTEGER NOT NULL REFERENCES item (item_id) ON DELETE RESTRICT,
    status   VARCHAR(12) NOT NULL DEFAULT 'available'
             CHECK (status IN ('available','checked_out','lost','damaged'))
);

CREATE TABLE loan (
    loan_id        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    copy_id        INTEGER NOT NULL REFERENCES copy (copy_id)         ON DELETE RESTRICT,
    user_id        INTEGER NOT NULL REFERENCES library_user (user_id) ON DELETE RESTRICT,
    checkout_date  DATE NOT NULL DEFAULT CURRENT_DATE,
    due_date       DATE NOT NULL DEFAULT CURRENT_DATE + 14,
    return_date    DATE,                                   -- NULL = still on loan
    CONSTRAINT ck_loan_due_after_checkout    CHECK (due_date >= checkout_date),
    CONSTRAINT ck_loan_return_after_checkout CHECK (return_date IS NULL OR return_date >= checkout_date)
);

CREATE UNIQUE INDEX uq_loan_one_open_per_copy ON loan (copy_id) WHERE return_date IS NULL;


CREATE VIEW v_catalog AS
SELECT i.item_id, i.bib_num, i.title, i.media_type, i.publisher, i.publishing_date, i.dewey_decimal_id,
       COALESCE(b.author, p.author, a.author)          AS author,
       b.isbn, p.issn, p.volume,
       COALESCE(a.duration_minutes, v.duration_minutes) AS duration_minutes,
       v.region_code, v.rating
FROM item i
LEFT JOIN book       b ON b.item_id = i.item_id
LEFT JOIN periodical p ON p.item_id = i.item_id
LEFT JOIN audio      a ON a.item_id = i.item_id
LEFT JOIN video      v ON v.item_id = i.item_id;

CREATE VIEW v_item_availability AS
SELECT i.item_id, i.title, i.media_type,
       COUNT(c.copy_id)                                  AS total_copies,
       COUNT(c.copy_id) FILTER (WHERE c.status = 'available') AS available_copies
FROM item i
LEFT JOIN copy c ON c.item_id = i.item_id
GROUP BY i.item_id, i.title, i.media_type;

CREATE VIEW v_overdue_loans AS
SELECT l.loan_id, l.copy_id, i.item_id, i.title, u.user_id, u.name, u.email,
       l.checkout_date, l.due_date, CURRENT_DATE - l.due_date AS days_overdue
FROM loan l
JOIN copy c         ON c.copy_id = l.copy_id
JOIN item i         ON i.item_id = c.item_id
JOIN library_user u ON u.user_id = l.user_id
WHERE l.return_date IS NULL AND l.due_date < CURRENT_DATE;

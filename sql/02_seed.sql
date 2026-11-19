-- =====================================================================
-- 02_seed.sql  --  Real catalog + generated patrons and loans
--
-- Catalog: Seattle Public Library "Library Collection Inventory" open dataset
--   (data.seattle.gov, dataset 6vkj-f5xf), 20,000-row sample from the
--   2017-01-01 snapshot -> data/spl_catalog_sample.csv.
--   One CSV row = one title at one branch; rows are merged per BibNum and
--   ItemCount is summed to give the number of physical copies.
-- Patrons and loans are generated: libraries never publish them (privacy).
--
-- Run from the repo root (\copy reads the CSV relative to the current directory).
-- =====================================================================
SELECT setseed(0.42);

TRUNCATE loan, copy, library_user, video, audio, periodical, book, item RESTART IDENTITY CASCADE;
ALTER TABLE loan DISABLE TRIGGER USER;   -- bulk load: skip any business-rule triggers added later; re-enabled at the end

-- ---------- 1. Stage the raw CSV exactly as exported (all text) ----------
CREATE TEMP TABLE stg_spl (
    bibnum text, title text, author text, isbn text, publicationyear text, publisher text,
    subjects text, itemtype text, itemcollection text, floatingitem text, itemlocation text,
    reportdate text, itemcount text);
\copy stg_spl FROM 'data/spl_catalog_sample.csv' WITH (FORMAT csv, HEADER true)

-- ---------- 2. Map SPL item-type codes to our media types, one row per title ----------
-- Codes are <audience><format>, e.g. acbk = adult circulating book, jcdvd = juvenile DVD.
-- Maps, microfilm, kits, pamphlets, CD-ROMs, unknown codes and rows without a title are not loaded.
CREATE TEMP TABLE stg_title AS
WITH typed AS (
    SELECT *, CASE
                WHEN itemtype ~ '(bk|mus)$'     THEN 'book'        -- books and printed music scores
                WHEN itemtype ~ '(cd|cas|rec)$' THEN 'audio'       -- CDs, cassettes, vinyl
                WHEN itemtype ~ '(dvd|vhs)$'    THEN 'video'
                WHEN itemtype ~ '(per|np)$'     THEN 'periodical'  -- periodicals, newspapers
              END AS media_type
    FROM stg_spl
)
SELECT bibnum::int AS bib_num, min(media_type) AS media_type,
       min(title) AS title, min(author) AS author, min(isbn) AS isbn,
       min(publicationyear) AS pub_year, min(publisher) AS publisher,
       sum(itemcount::int)::int AS copies
FROM typed
WHERE media_type IS NOT NULL
  AND NULLIF(btrim(title), '') IS NOT NULL      -- 86 rows are bare inventory records with no metadata
GROUP BY bibnum;

-- ---------- 3. Clean the MARC-style text fields ----------
CREATE TEMP TABLE stg_clean AS
SELECT bib_num, media_type, copies,
       -- "Title : subtitle / by Someone." -> "Title : subtitle"
       left(rtrim(regexp_replace(title, '\s+/\s.*$', ''), ' :;,./'), 255)               AS title,
       -- "Bach, Johann Sebastian, 1685-1750," -> "Bach, Johann Sebastian"
       left(NULLIF(rtrim(regexp_replace(author, ',\s*[0-9?]{3,4}-.*$', ''), ' ,'), ''), 150) AS author,
       COALESCE(substring(isbn FROM '97[89][0-9]{10}'), substring(isbn FROM '[0-9]{9}[0-9X]')) AS isbn,
       substring(pub_year FROM '(1[4-9][0-9]{2}|20[0-9]{2})')::int                      AS year,
       -- "[Tribeca Films : Cinedigm,]" -> "Tribeca Films : Cinedigm"
       left(NULLIF(btrim(publisher, ' ,:;[]'), ''), 150)                                AS publisher
FROM stg_title;

-- The same ISBN can sit on two bib records (e.g. a reissue); keep it on the lowest BibNum only.
UPDATE stg_clean s SET isbn = NULL
FROM (SELECT bib_num, row_number() OVER (PARTITION BY isbn ORDER BY bib_num) AS rn
      FROM stg_clean WHERE isbn IS NOT NULL) d
WHERE d.bib_num = s.bib_num AND d.rn > 1;

-- ---------- 4. Load supertype + subtypes ----------
INSERT INTO item (bib_num, title, publisher, media_type, publishing_date)
SELECT bib_num, title, publisher, media_type,
       CASE WHEN year BETWEEN 1450 AND 2017 THEN make_date(year, 1, 1) END   -- year only -> Jan 1
FROM stg_clean ORDER BY bib_num;

INSERT INTO book (item_id, author, isbn)
SELECT i.item_id, s.author, s.isbn FROM item i JOIN stg_clean s USING (bib_num) WHERE i.media_type = 'book';
INSERT INTO periodical (item_id, author)
SELECT i.item_id, s.author FROM item i JOIN stg_clean s USING (bib_num) WHERE i.media_type = 'periodical';
INSERT INTO audio (item_id, author)
SELECT i.item_id, s.author FROM item i JOIN stg_clean s USING (bib_num) WHERE i.media_type = 'audio';
INSERT INTO video (item_id)
SELECT i.item_id FROM item i WHERE i.media_type = 'video';

-- ---------- 5. Copies: ItemCount physical copies per title ----------
-- A small share is marked lost/damaged so those code paths have data.
INSERT INTO copy (item_id, status)
SELECT item_id,
       CASE WHEN n % 97 = 0 THEN 'lost' WHEN n % 53 = 0 THEN 'damaged' ELSE 'available' END
FROM (SELECT i.item_id, row_number() OVER (ORDER BY i.item_id, g) AS n
      FROM item i JOIN stg_clean s USING (bib_num), generate_series(1, s.copies) g) c
ORDER BY n;

-- ---------- 6. Generated users: ids 1-40 are employees, the rest patrons ----------
INSERT INTO library_user (name, email, role, status)
SELECT (ARRAY['Maria','James','Wei','Priya','Carlos','Aiko','Fatima','Liam','Sofia','Noah','Yuki','Omar'])[1 + g % 12] || ' ' ||
       (ARRAY['Garcia','Smith','Nguyen','Patel','Kim','Silva','Tanaka','Brown','Lopez','Chen','Ali','Johnson','Do'])[1 + (g * 5) % 13],
       'user' || g || '@queryme-library.org',
       CASE WHEN g <= 4 THEN 'librarian' WHEN g <= 40 THEN 'staff' ELSE 'patron' END,
       CASE WHEN g > 40 AND g % 25 = 0 THEN 'suspended'
            WHEN g > 40 AND g % 40 = 0 THEN 'expired'
            ELSE 'active' END
FROM generate_series(1, 2000) g
ORDER BY g;

-- ---------- 7. Generated loan history: 100,000 returned loans over ~2 years ----------
INSERT INTO loan (copy_id, user_id, checkout_date, due_date, return_date)
SELECT copy_id, user_id, co, co + 14, co + ret
FROM (SELECT 1 + floor(random() * n.copies)::int               AS copy_id,
             1 + floor(random() * 2000)::int                   AS user_id,
             CURRENT_DATE - 30 - floor(random() * 700)::int    AS co,
             1 + floor(random() * 20)::int                     AS ret     -- ~30% returned late
      FROM generate_series(1, 100000), (SELECT count(*) AS copies FROM copy) n) s;

-- ---------- 8. 600 open loans on available copies, round-robin over active patrons ----------
WITH patrons AS (
    SELECT array_agg(user_id ORDER BY user_id) AS arr
    FROM library_user WHERE status = 'active' AND role = 'patron'
), picked AS (
    SELECT copy_id, row_number() OVER (ORDER BY random()) AS n
    FROM copy WHERE status = 'available'
)
INSERT INTO loan (copy_id, user_id, checkout_date, due_date, return_date)
SELECT p.copy_id, pa.arr[1 + (p.n % cardinality(pa.arr))::int],
       CURRENT_DATE - (p.n % 30)::int, CURRENT_DATE - (p.n % 30)::int + 14, NULL   -- ~half overdue
FROM picked p CROSS JOIN patrons pa
WHERE p.n <= 600;

UPDATE copy SET status = 'checked_out'
WHERE copy_id IN (SELECT copy_id FROM loan WHERE return_date IS NULL);

ALTER TABLE loan ENABLE TRIGGER USER;
ANALYZE;

\echo 'rows loaded from CSV / titles kept / skipped (non-library media types):'
SELECT (SELECT count(*) FROM stg_spl) AS csv_rows,
       (SELECT count(*) FROM stg_clean) AS titles_loaded,
       (SELECT count(DISTINCT bibnum) FROM stg_spl) - (SELECT count(*) FROM stg_clean) AS titles_skipped_type_or_no_title;

SELECT 'item' AS table_name, count(*) FROM item
UNION ALL SELECT 'book', count(*) FROM book
UNION ALL SELECT 'periodical', count(*) FROM periodical
UNION ALL SELECT 'audio', count(*) FROM audio
UNION ALL SELECT 'video', count(*) FROM video
UNION ALL SELECT 'library_user', count(*) FROM library_user
UNION ALL SELECT 'copy', count(*) FROM copy
UNION ALL SELECT 'loan', count(*) FROM loan;

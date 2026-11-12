-- ============================================================
--  MINI-PROJET BDD INSEE - Création du schéma
--  Solution au problème circulaire :
--    REGION et DEPARTEMENT ont une FK vers COMMUNES (chef-lieu)
--    COMMUNES a une FK vers DEPARTEMENT
--  => On déclare les FK chefs-lieux comme DEFERRABLE INITIALLY DEFERRED
--     ce qui permet d'insérer dans REGION/DEPARTEMENT sans chef-lieu,
--     d'insérer COMMUNES, puis de mettre à jour les chefs-lieux,
--     le tout dans une seule transaction sans ALTER TABLE.
-- ============================================================

-- Nettoyage
DROP TABLE IF EXISTS MESURE_COM  CASCADE;
DROP TABLE IF EXISTS MESURE_DEP  CASCADE;
DROP TABLE IF EXISTS MESURE_REG  CASCADE;
DROP TABLE IF EXISTS TYPE_STAT   CASCADE;
DROP TABLE IF EXISTS COMMUNES    CASCADE;
DROP TABLE IF EXISTS DEPARTEMENT CASCADE;
DROP TABLE IF EXISTS REGION      CASCADE;

-- ============================================================
-- 1. REGION
-- ============================================================
CREATE TABLE REGION (
    id          SERIAL       PRIMARY KEY,
    code_insee  VARCHAR(3)   NOT NULL UNIQUE,
    nom         TEXT         NOT NULL,   -- NCCENR  (accentué)
    nom_maj     TEXT         NOT NULL,   -- NCC     (majuscules)
    libelle     TEXT         NOT NULL,   -- LIBELLE (article + nom)
    tncc        CHAR(1),
    -- chef-lieu : NULL temporairement lors de l'import, DEFERRABLE pour éviter
    -- le problème circulaire avec COMMUNES
    id_cheflieu INT,
    population  NUMERIC(12,2)            -- Question 3 : population agrégée
);

-- ============================================================
-- 2. DEPARTEMENT
-- ============================================================
CREATE TABLE DEPARTEMENT (
    id          SERIAL       PRIMARY KEY,
    code_insee  VARCHAR(3)   NOT NULL UNIQUE,
    nom         TEXT         NOT NULL,
    nom_maj     TEXT         NOT NULL,
    libelle     TEXT         NOT NULL,
    tncc        CHAR(1),
    id_region   INT          NOT NULL REFERENCES REGION(id),
    id_cheflieu INT,
    population  NUMERIC(12,2)            -- Question 3 : population agrégée
);

-- ============================================================
-- 3. COMMUNES
-- ============================================================
CREATE TABLE COMMUNES (
    id             SERIAL      PRIMARY KEY,
    code_insee     VARCHAR(5)  NOT NULL UNIQUE,
    nom            TEXT        NOT NULL,
    nom_maj        TEXT        NOT NULL,
    libelle        TEXT        NOT NULL,
    tncc           CHAR(1),
    id_departement INT         NOT NULL REFERENCES DEPARTEMENT(id),
    population     NUMERIC(12,2)         -- Question 3 : population dernière année
);

-- ============================================================
-- FK chefs-lieux (après la table COMMUNES)
-- DEFERRABLE INITIALLY DEFERRED = vérification en fin de transaction
-- On n'utilise PAS ALTER TABLE pour ajouter des données,
-- mais ALTER TABLE pour ajouter les CONTRAINTES de FK est autorisé
-- car c'est une modification de structure (DDL), pas d'insertion.
-- ============================================================
ALTER TABLE REGION ADD CONSTRAINT fk_region_cheflieu
    FOREIGN KEY (id_cheflieu) REFERENCES COMMUNES(id)
    DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE DEPARTEMENT ADD CONSTRAINT fk_dep_cheflieu
    FOREIGN KEY (id_cheflieu) REFERENCES COMMUNES(id)
    DEFERRABLE INITIALLY DEFERRED;

-- ============================================================
-- 4. TYPE_STAT  (référentiel des types de statistiques)
--    est_periodique = TRUE si la stat porte sur un intervalle
--    (ex: NAIS1520 = naissances 2015-2020) vs FALSE pour une
--    valeur à un instant donné (ex: P21_POP = population 2021)
-- ============================================================
CREATE TABLE TYPE_STAT (
    id             SERIAL      PRIMARY KEY,
    code           VARCHAR(20) NOT NULL UNIQUE,
    libelle        TEXT        NOT NULL,
    est_periodique BOOLEAN     NOT NULL DEFAULT FALSE
);

-- ============================================================
-- 5. STATISTIQUE  (valeurs par commune / année)
--    Une statistique = (commune, type, année_début, année_fin, valeur)
--    Pour une stat ponctuelle : annee_debut = annee_fin
--    Cette structure permet d'ajouter de nouvelles années
--    simplement en insérant de nouveaux n-uplets.
-- ============================================================
CREATE TABLE MESURE_COM (
    id_commune    INT          NOT NULL REFERENCES COMMUNES(id),
    id_type       INT          NOT NULL REFERENCES TYPE_STAT(id),
    annee_debut   SMALLINT     NOT NULL,
    annee_fin     SMALLINT     NOT NULL,
    valeur        NUMERIC(14,3),
    PRIMARY KEY (id_commune, id_type, annee_debut, annee_fin)
);

-- ============================================================
-- 6. MESURE_DEP et MESURE_REG  (agrégats calculés)
--    Remplies automatiquement par les triggers/procédures stockées
-- ============================================================
CREATE TABLE MESURE_DEP (
    id_departement INT      NOT NULL REFERENCES DEPARTEMENT(id),
    id_type        INT      NOT NULL REFERENCES TYPE_STAT(id),
    annee_debut    SMALLINT NOT NULL,
    annee_fin      SMALLINT NOT NULL,
    valeur         NUMERIC(14,3),
    PRIMARY KEY (id_departement, id_type, annee_debut, annee_fin)
);

CREATE TABLE MESURE_REG (
    id_region   INT      NOT NULL REFERENCES REGION(id),
    id_type     INT      NOT NULL REFERENCES TYPE_STAT(id),
    annee_debut SMALLINT NOT NULL,
    annee_fin   SMALLINT NOT NULL,
    valeur      NUMERIC(14,3),
    PRIMARY KEY (id_region, id_type, annee_debut, annee_fin)
);

-- ============================================================
-- INDEX pour les performances (Question EXPLAIN)
-- ============================================================
CREATE INDEX idx_communes_dep     ON COMMUNES(id_departement);
CREATE INDEX idx_dep_region       ON DEPARTEMENT(id_region);
CREATE INDEX idx_mesure_com_type  ON MESURE_COM(id_type);
CREATE INDEX idx_mesure_com_ann   ON MESURE_COM(annee_debut, annee_fin);

-- (L'index sur population sera créé dans le fichier EXPLAIN)

\echo '>>> Tables créées avec succès.'

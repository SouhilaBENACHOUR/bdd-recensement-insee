-- ============================================================
--  04_vues_procedures_triggers.sql
--  Questions 2 à 6 du projet
-- ============================================================

-- ============================================================
-- QUESTION 2 : VUES
-- Vue 1 : Population des départements par année
-- Vue 2 : Population des régions par année + indicateurs
-- ============================================================

CREATE OR REPLACE VIEW vue_pop_departements AS
    SELECT
        d.id                AS id_departement,
        d.code_insee        AS code_dep,
        d.nom               AS departement,
        r.nom               AS region,
        ts.code             AS type_stat,
        ts.libelle          AS libelle_stat,
        mc.annee_debut,
        mc.annee_fin,
        SUM(mc.valeur)      AS valeur_totale
    FROM DEPARTEMENT d
    JOIN REGION r           ON r.id = d.id_region
    JOIN COMMUNES c         ON c.id_departement = d.id
    JOIN MESURE_COM mc      ON mc.id_commune = c.id
    JOIN TYPE_STAT ts       ON ts.id = mc.id_type
    GROUP BY d.id, d.code_insee, d.nom, r.nom,
             ts.code, ts.libelle, mc.annee_debut, mc.annee_fin;

COMMENT ON VIEW vue_pop_departements IS
    'Population et indicateurs agrégés par département, type de stat et année';

-- -------------------------------------------------------
CREATE OR REPLACE VIEW vue_pop_regions AS
    SELECT
        r.id                AS id_region,
        r.code_insee        AS code_reg,
        r.nom               AS region,
        ts.code             AS type_stat,
        ts.libelle          AS libelle_stat,
        mc.annee_debut,
        mc.annee_fin,
        SUM(mc.valeur)      AS valeur_totale
    FROM REGION r
    JOIN DEPARTEMENT d  ON d.id_region = r.id
    JOIN COMMUNES c     ON c.id_departement = d.id
    JOIN MESURE_COM mc  ON mc.id_commune = c.id
    JOIN TYPE_STAT ts   ON ts.id = mc.id_type
    GROUP BY r.id, r.code_insee, r.nom,
             ts.code, ts.libelle, mc.annee_debut, mc.annee_fin;

COMMENT ON VIEW vue_pop_regions IS
    'Population et indicateurs agrégés par région, type de stat et année';

-- Exemple d'utilisation :
-- SELECT * FROM vue_pop_regions WHERE type_stat = 'POP' ORDER BY annee_debut, valeur_totale DESC;


-- ============================================================
-- QUESTION 3 : Colonnes population (déjà dans CREATE TABLE)
-- On ajoute seulement si le script 01 n'a pas été rejoué
-- ============================================================
-- ALTER TABLE COMMUNES    ADD COLUMN IF NOT EXISTS population NUMERIC(12,2);
-- ALTER TABLE DEPARTEMENT ADD COLUMN IF NOT EXISTS population NUMERIC(12,2);
-- ALTER TABLE REGION      ADD COLUMN IF NOT EXISTS population NUMERIC(12,2);


-- ============================================================
-- QUESTION 4 : PROCÉDURES STOCKÉES
-- ============================================================

-- Procédure 1 : Recalcule la population d'UNE commune
--               à partir de la dernière année disponible dans MESURE_COM
CREATE OR REPLACE FUNCTION calc_pop_commune(p_id_commune INT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_pop NUMERIC(14,3);
BEGIN
    SELECT mc.valeur INTO v_pop
    FROM MESURE_COM mc
    JOIN TYPE_STAT ts ON ts.id = mc.id_type
    WHERE mc.id_commune = p_id_commune
      AND ts.code = 'POP'
      AND mc.annee_debut = mc.annee_fin   -- stat ponctuelle
    ORDER BY mc.annee_debut DESC
    LIMIT 1;

    UPDATE COMMUNES
    SET population = v_pop
    WHERE id = p_id_commune;
END;
$$;

-- -------------------------------------------------------
-- Procédure 2 : Recalcule la population d'UN département
--               à partir des colonnes population des communes
--               UNIQUEMENT si toutes les communes du département
--               ont une population renseignée.
CREATE OR REPLACE FUNCTION calc_pop_departement(p_id_dep INT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_nb_total   INT;
    v_nb_remplis INT;
    v_pop        NUMERIC(14,3);
BEGIN
    -- Vérifier que toutes les communes sont renseignées
    SELECT COUNT(*),
           COUNT(population)
    INTO v_nb_total, v_nb_remplis
    FROM COMMUNES
    WHERE id_departement = p_id_dep;

    IF v_nb_total = 0 OR v_nb_total != v_nb_remplis THEN
        -- Calcul non pertinent : on ne fait rien
        RETURN;
    END IF;

    SELECT SUM(population)
    INTO v_pop
    FROM COMMUNES
    WHERE id_departement = p_id_dep;

    UPDATE DEPARTEMENT
    SET population = v_pop
    WHERE id = p_id_dep;
END;
$$;

-- -------------------------------------------------------
-- Procédure 3 : Recalcule la population d'UNE région
--               à partir des colonnes population des départements
--               UNIQUEMENT si tous les départements ont leur population.
CREATE OR REPLACE FUNCTION calc_pop_region(p_id_reg INT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_nb_total   INT;
    v_nb_remplis INT;
    v_pop        NUMERIC(14,3);
BEGIN
    SELECT COUNT(*),
           COUNT(population)
    INTO v_nb_total, v_nb_remplis
    FROM DEPARTEMENT
    WHERE id_region = p_id_reg;

    IF v_nb_total = 0 OR v_nb_total != v_nb_remplis THEN
        RETURN;
    END IF;

    SELECT SUM(population)
    INTO v_pop
    FROM DEPARTEMENT
    WHERE id_region = p_id_reg;

    UPDATE REGION
    SET population = v_pop
    WHERE id = p_id_reg;
END;
$$;

-- -------------------------------------------------------
-- Procédure 4 : Recalcule TOUTES les populations (bulk)
--               Utile après un import initial
CREATE OR REPLACE FUNCTION recalculer_toutes_populations()
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_commune    RECORD;
    v_dep        RECORD;
    v_reg        RECORD;
BEGIN
    RAISE NOTICE 'Calcul population communes...';
    FOR v_commune IN SELECT id FROM COMMUNES LOOP
        PERFORM calc_pop_commune(v_commune.id);
    END LOOP;

    RAISE NOTICE 'Calcul population départements...';
    FOR v_dep IN SELECT id FROM DEPARTEMENT LOOP
        PERFORM calc_pop_departement(v_dep.id);
    END LOOP;

    RAISE NOTICE 'Calcul population régions...';
    FOR v_reg IN SELECT id FROM REGION LOOP
        PERFORM calc_pop_region(v_reg.id);
    END LOOP;

    RAISE NOTICE 'Recalcul terminé.';
END;
$$;

-- Lancer le recalcul initial :
-- SELECT recalculer_toutes_populations();


-- ============================================================
-- QUESTION 5a : TRIGGERS — Mise à jour en cascade
--               Quand MESURE_COM est modifié, recalculer
--               la chaîne commune -> département -> région
-- ============================================================

CREATE OR REPLACE FUNCTION trigger_maj_pop_commune()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_id_dep INT;
    v_id_reg INT;
BEGIN
    -- Recalculer la commune concernée
    PERFORM calc_pop_commune(NEW.id_commune);

    -- Trouver le département de cette commune
    SELECT id_departement INTO v_id_dep
    FROM COMMUNES WHERE id = NEW.id_commune;

    -- Recalculer le département (seulement si pertinent)
    PERFORM calc_pop_departement(v_id_dep);

    -- Trouver la région de ce département
    SELECT id_region INTO v_id_reg
    FROM DEPARTEMENT WHERE id = v_id_dep;

    -- Recalculer la région (seulement si pertinent)
    PERFORM calc_pop_region(v_id_reg);

    RETURN NEW;
END;
$$;

-- Trigger sur INSERT et UPDATE de MESURE_COM
DROP TRIGGER IF EXISTS trig_maj_pop ON MESURE_COM;
CREATE TRIGGER trig_maj_pop
    AFTER INSERT OR UPDATE ON MESURE_COM
    FOR EACH ROW
    -- N'activer que si c'est une stat population ponctuelle
    WHEN (NEW.annee_debut = NEW.annee_fin)
    EXECUTE FUNCTION trigger_maj_pop_commune();


-- ============================================================
-- QUESTION 5b : Rendre REGION et DEPARTEMENT non modifiables
--               Bloquer INSERT, UPDATE, DELETE sur ces tables
-- ============================================================

-- Fonction générique de blocage
CREATE OR REPLACE FUNCTION bloquer_modification()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION
        'La table % est en lecture seule. '
        'Les modifications sont interdites (INSERT/UPDATE/DELETE).',
        TG_TABLE_NAME;
    RETURN NULL;
END;
$$;

-- Triggers sur REGION
DROP TRIGGER IF EXISTS trig_region_readonly_insert ON REGION;
DROP TRIGGER IF EXISTS trig_region_readonly_update ON REGION;
DROP TRIGGER IF EXISTS trig_region_readonly_delete ON REGION;

CREATE TRIGGER trig_region_readonly_insert
    BEFORE INSERT ON REGION
    FOR EACH ROW EXECUTE FUNCTION bloquer_modification();

CREATE TRIGGER trig_region_readonly_update
    BEFORE UPDATE ON REGION
    FOR EACH ROW EXECUTE FUNCTION bloquer_modification();

CREATE TRIGGER trig_region_readonly_delete
    BEFORE DELETE ON REGION
    FOR EACH ROW EXECUTE FUNCTION bloquer_modification();

-- Triggers sur DEPARTEMENT
DROP TRIGGER IF EXISTS trig_dep_readonly_insert ON DEPARTEMENT;
DROP TRIGGER IF EXISTS trig_dep_readonly_update ON DEPARTEMENT;
DROP TRIGGER IF EXISTS trig_dep_readonly_delete ON DEPARTEMENT;

CREATE TRIGGER trig_dep_readonly_insert
    BEFORE INSERT ON DEPARTEMENT
    FOR EACH ROW EXECUTE FUNCTION bloquer_modification();

CREATE TRIGGER trig_dep_readonly_update
    BEFORE UPDATE ON DEPARTEMENT
    FOR EACH ROW EXECUTE FUNCTION bloquer_modification();

CREATE TRIGGER trig_dep_readonly_delete
    BEFORE DELETE ON DEPARTEMENT
    FOR EACH ROW EXECUTE FUNCTION bloquer_modification();

-- NOTE : Pour réactiver temporairement les modifications (ex: import initial),
-- désactiver les triggers : ALTER TABLE REGION DISABLE TRIGGER ALL;
-- puis les réactiver : ALTER TABLE REGION ENABLE TRIGGER ALL;


-- ============================================================
-- QUESTION 5c : Ajout automatique d'une nouvelle année
--               Trigger sur INSERT de MESURE_COM pour POP
--               → recalcul automatique de la chaîne dep/reg
--               si TOUTES les communes de l'entité ont la donnée
--
-- Ce trigger est le MÊME que trig_maj_pop défini plus haut.
-- La logique est déjà dans calc_pop_departement et calc_pop_region :
-- "calculer seulement si toutes les communes/dép ont leur valeur."
-- Ainsi, quand on insère la dernière commune d'un département,
-- le département se calcule automatiquement, puis la région.
-- ============================================================

-- Aucun code supplémentaire nécessaire : la factorisation dans
-- calc_pop_departement / calc_pop_region suffit.


-- ============================================================
-- QUESTION 6 : EXPLAIN — Plans d'exécution
-- ============================================================

-- Test 1 : Requête simple sans index sur population
-- (Avant création de l'index)
EXPLAIN ANALYZE
    SELECT nom, population
    FROM COMMUNES
    WHERE population < 5000
    ORDER BY population DESC;

-- Créer l'index
CREATE INDEX IF NOT EXISTS idx_communes_population ON COMMUNES(population);

-- Test 2 : Même requête AVEC l'index
-- Le SGBD devrait utiliser un Index Scan au lieu d'un Seq Scan
EXPLAIN ANALYZE
    SELECT nom, population
    FROM COMMUNES
    WHERE population < 5000
    ORDER BY population DESC;

-- Test 3 : Jointure petite table × grande table
-- DEPARTEMENT (101 lignes) × COMMUNES (~35 000)
-- Le SGBD choisit probablement un Hash Join
EXPLAIN ANALYZE
    SELECT d.nom AS departement, c.nom AS commune
    FROM DEPARTEMENT d
    JOIN COMMUNES c ON c.id_departement = d.id
    WHERE d.code_insee = '33';

-- Test 4 : Jointure grande × grande × grande
-- Montre un plan plus complexe (3 tables, possiblement Merge Join ou Hash Join)
EXPLAIN ANALYZE
    SELECT r.nom, d.nom, c.nom, mc.valeur
    FROM REGION r
    JOIN DEPARTEMENT d  ON d.id_region = r.id
    JOIN COMMUNES c     ON c.id_departement = d.id
    JOIN MESURE_COM mc  ON mc.id_commune = c.id
    JOIN TYPE_STAT ts   ON ts.id = mc.id_type
    WHERE ts.code = 'POP'
      AND mc.annee_debut = 2021;

-- Test 5 : Requête avec tri + agrégation (plan le plus long)
-- Le SGBD doit : filtrer MESURE_COM, joindre 4 tables, grouper, trier
EXPLAIN ANALYZE
    SELECT
        r.nom                       AS region,
        d.nom                       AS departement,
        COUNT(DISTINCT c.id)        AS nb_communes,
        SUM(mc.valeur)::BIGINT      AS population_totale,
        AVG(mc.valeur)::INT         AS pop_moyenne_commune,
        MAX(mc.valeur)::BIGINT      AS plus_grande_commune,
        MIN(mc.valeur)::BIGINT      AS plus_petite_commune
    FROM REGION r
    JOIN DEPARTEMENT d  ON d.id_region = r.id
    JOIN COMMUNES c     ON c.id_departement = d.id
    JOIN MESURE_COM mc  ON mc.id_commune = c.id
    JOIN TYPE_STAT ts   ON ts.id = mc.id_type
    WHERE ts.code      = 'POP'
      AND mc.annee_debut = 2021
      AND mc.annee_fin   = 2021
    GROUP BY r.nom, d.nom
    HAVING SUM(mc.valeur) > 100000
    ORDER BY population_totale DESC;

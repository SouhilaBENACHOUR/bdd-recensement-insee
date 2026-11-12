"""
02_import_donnees.py
====================
Import des données INSEE dans PostgreSQL.

Stratégie pour le problème circulaire chef-lieu :
  - REGION et DEPARTEMENT ont une FK DEFERRABLE vers COMMUNES(id_cheflieu)
  - On insère d'abord REGION et DEPARTEMENT (id_cheflieu = NULL)
  - On importe COMMUNES avec COPY (ultra-rapide)
  - On met à jour id_cheflieu dans une transaction avec SET CONSTRAINTS DEFERRED
  => Aucun ALTER TABLE pour les données, aucun DROP/RECREATE

Utilisation de COPY (psycopg3) pour les gros volumes :
  - COMMUNES   : ~35 000 lignes
  - MESURE_COM : ~350 000 lignes
"""

import psycopg
import pandas as pd
import io
import sys
import os

# ============================================================
# CONFIGURATION
# ============================================================
DB_CONFIG = {
    "host":     "pgsql",
    "dbname":   "soubenachour",
    "user":     "soubenachour",
    "password": "VOTRE_MOT_DE_PASSE"
}

# Chemin vers les fichiers CSV
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE_DIR, "..", "data")

FICHIER_REGIONS      = os.path.join(DATA_DIR, "referentiels", "v_region_2024.csv")
FICHIER_DEPARTEMENTS = os.path.join(DATA_DIR, "referentiels", "v_departement_2024.csv")
FICHIER_COMMUNES     = os.path.join(DATA_DIR, "referentiels", "v_commune_2024.csv")
FICHIER_STATS        = os.path.join(DATA_DIR, "recensement", "base-cc-serie-historique-2021.CSV")

# ============================================================
# STATISTIQUES À IMPORTER
# (colonne_csv, code_type, libelle, annee_debut, annee_fin, est_periodique)
#
# Règle du projet : les nouvelles années = nouveaux n-uplets seulement.
# Pour chaque stat on définit l'intervalle (ponctuel si debut==fin).
# ============================================================
STATS_A_IMPORTER = [
    # Population (ponctuelle à chaque recensement)
    ("P21_POP",    "POP",  "Population",              2021, 2021, False),
    ("P15_POP",    "POP",  "Population",              2015, 2015, False),
    ("P10_POP",    "POP",  "Population",              2010, 2010, False),
    ("D99_POP",    "POP",  "Population",              1999, 1999, False),
    ("D90_POP",    "POP",  "Population",              1990, 1990, False),
    ("D82_POP",    "POP",  "Population",              1982, 1982, False),
    ("D75_POP",    "POP",  "Population",              1975, 1975, False),
    ("D68_POP",    "POP",  "Population",              1968, 1968, False),
    # Naissances (périodiques : sur un intervalle)
    ("NAIS1520",   "NAIS", "Naissances",              2015, 2020, True),
    ("NAIS1014",   "NAIS", "Naissances",              2010, 2014, True),
    ("NAIS9909",   "NAIS", "Naissances",              1999, 2009, True),
    ("NAIS9099",   "NAIS", "Naissances",              1990, 1999, True),
    ("NAIS8290",   "NAIS", "Naissances",              1982, 1990, True),
    # Décès (périodiques)
    ("DECE1520",   "DEC",  "Décès",                   2015, 2020, True),
    ("DECE1014",   "DEC",  "Décès",                   2010, 2014, True),
    ("DECE9909",   "DEC",  "Décès",                   1999, 2009, True),
    # Logements (ponctuels)
    ("P21_LOG",    "LOG",  "Logements",               2021, 2021, False),
    ("P15_LOG",    "LOG",  "Logements",               2015, 2015, False),
    # Résidences principales (ponctuelles)
    ("P21_RP",     "RP",   "Résidences principales",  2021, 2021, False),
    ("P15_RP",     "RP",   "Résidences principales",  2015, 2015, False),
    # Superficie (ponctuelle, sans année : on met 0,0)
    ("SUPERF",     "SUP",  "Superficie (km²)",        0,    0,    False),
]


def connect():
    """Retourne une connexion psycopg3."""
    return psycopg.connect(**DB_CONFIG)


def importer_regions(conn):
    """Insère les régions (sans chef-lieu pour l'instant)."""
    print("► Import régions...")
    df = pd.read_csv(FICHIER_REGIONS, dtype=str, sep=",")
    rows = [
        (row["REG"], row["NCCENR"], row["NCC"], row["LIBELLE"], row["TNCC"])
        for _, row in df.iterrows()
    ]
    with conn.cursor() as cur:
        with cur.copy("""
            COPY REGION (code_insee, nom, nom_maj, libelle, tncc)
            FROM STDIN (FORMAT TEXT)
        """) as copy:
            for r in rows:
                copy.write_row(r)
    conn.commit()
    print(f"  ✓ {len(rows)} régions")
    return df


def importer_departements(conn):
    """Insère les départements (sans chef-lieu pour l'instant)."""
    print("► Import départements...")
    df = pd.read_csv(FICHIER_DEPARTEMENTS, dtype=str, sep=",")

    with conn.cursor() as cur:
        # Récupérer le mapping code_reg -> id_region
        cur.execute("SELECT code_insee, id FROM REGION")
        reg_ids = {r[0]: r[1] for r in cur.fetchall()}

        rows = []
        for _, row in df.iterrows():
            id_reg = reg_ids.get(row["REG"])
            if id_reg:
                rows.append((row["DEP"], row["NCCENR"], row["NCC"],
                             row["LIBELLE"], row["TNCC"], id_reg))

        with cur.copy("""
            COPY DEPARTEMENT (code_insee, nom, nom_maj, libelle, tncc, id_region)
            FROM STDIN (FORMAT TEXT)
        """) as copy:
            for r in rows:
                copy.write_row(r)
    conn.commit()
    print(f"  ✓ {len(rows)} départements")
    return df


def importer_communes(conn):
    """Insère les communes de type COM avec COPY."""
    print("► Import communes (type COM uniquement)...")
    df = pd.read_csv(FICHIER_COMMUNES, dtype=str, sep=",")
    df = df[df["TYPECOM"] == "COM"].copy()

    with conn.cursor() as cur:
        cur.execute("SELECT code_insee, id FROM DEPARTEMENT")
        dep_ids = {r[0]: r[1] for r in cur.fetchall()}

        rows = []
        for _, row in df.iterrows():
            id_dep = dep_ids.get(row["DEP"])
            if id_dep:
                rows.append((row["COM"], row["NCCENR"], row["NCC"],
                             row["LIBELLE"], row["TNCC"], id_dep))

        with cur.copy("""
            COPY COMMUNES (code_insee, nom, nom_maj, libelle, tncc, id_departement)
            FROM STDIN (FORMAT TEXT)
        """) as copy:
            for r in rows:
                copy.write_row(r)
    conn.commit()
    print(f"  ✓ {len(rows)} communes")
    return df


def mettre_a_jour_chefs_lieux(conn, df_reg, df_dep):
    """
    Met à jour id_cheflieu pour REGION et DEPARTEMENT.
    Utilise SET CONSTRAINTS ALL DEFERRED pour éviter les erreurs
    pendant la transaction (FK circulaire).
    """
    print("► Mise à jour chefs-lieux...")
    with conn.cursor() as cur:
        # Récupérer le mapping code_insee_commune -> id
        cur.execute("SELECT code_insee, id FROM COMMUNES")
        com_ids = {r[0]: r[1] for r in cur.fetchall()}

        # Activer le mode DEFERRED pour les FK chefs-lieux
        cur.execute("SET CONSTRAINTS fk_region_cheflieu, fk_dep_cheflieu DEFERRED")

        nb_reg, nb_dep = 0, 0
        for _, row in df_reg.iterrows():
            id_com = com_ids.get(row["CHEFLIEU"])
            if id_com:
                cur.execute(
                    "UPDATE REGION SET id_cheflieu = %s WHERE code_insee = %s",
                    (id_com, row["REG"])
                )
                nb_reg += 1

        for _, row in df_dep.iterrows():
            id_com = com_ids.get(row["CHEFLIEU"])
            if id_com:
                cur.execute(
                    "UPDATE DEPARTEMENT SET id_cheflieu = %s WHERE code_insee = %s",
                    (id_com, row["DEP"])
                )
                nb_dep += 1

    # La FK est vérifiée ici, au commit
    conn.commit()
    print(f"  ✓ {nb_reg} chefs-lieux régions, {nb_dep} chefs-lieux départements")


def importer_type_stats(conn):
    """Insère le référentiel des types de statistiques."""
    print("► Import types de statistiques...")
    seen = {}
    for (_, code, libelle, _, _, est_per) in STATS_A_IMPORTER:
        if code not in seen:
            seen[code] = (libelle, est_per)

    with conn.cursor() as cur:
        for code, (libelle, est_per) in seen.items():
            cur.execute("""
                INSERT INTO TYPE_STAT (code, libelle, est_periodique)
                VALUES (%s, %s, %s)
                ON CONFLICT (code) DO NOTHING
            """, (code, libelle, est_per))
    conn.commit()
    print(f"  ✓ {len(seen)} types de statistiques")


def importer_mesures(conn):
    """
    Importe les mesures communales avec COPY (performance).
    Charge uniquement les colonnes utiles du CSV (~35 Mo).
    """
    print("► Import mesures statistiques (COPY)...")

    cols_csv = ["CODGEO"] + [col for (col, *_) in STATS_A_IMPORTER]

    df = pd.read_csv(
        FICHIER_STATS,
        dtype=str,
        sep=";",
        usecols=lambda c: c in set(cols_csv)
    )

    with conn.cursor() as cur:
        # Mapping code_insee -> id commune
        cur.execute("SELECT code_insee, id FROM COMMUNES")
        com_ids = {r[0]: r[1] for r in cur.fetchall()}

        # Mapping code_type -> id type_stat
        cur.execute("SELECT code, id FROM TYPE_STAT")
        type_ids = {r[0]: r[1] for r in cur.fetchall()}

        # Construire les lignes à insérer
        rows = []
        for _, row in df.iterrows():
            id_com = com_ids.get(row["CODGEO"])
            if not id_com:
                continue
            for (col_csv, code_type, _, ann_d, ann_f, _) in STATS_A_IMPORTER:
                if col_csv not in row.index:
                    continue
                val_raw = row[col_csv]
                if pd.isna(val_raw) or val_raw == "":
                    continue
                try:
                    valeur = float(str(val_raw).replace(",", "."))
                except ValueError:
                    continue
                rows.append((id_com, type_ids[code_type], ann_d, ann_f, valeur))

        # COPY en masse
        with cur.copy("""
            COPY MESURE_COM (id_commune, id_type, annee_debut, annee_fin, valeur)
            FROM STDIN (FORMAT TEXT)
        """) as copy:
            for r in rows:
                copy.write_row(r)

    conn.commit()
    print(f"  ✓ {len(rows):,} mesures importées")


def main():
    print("=" * 55)
    print("  IMPORT BASE INSEE - Régions/Dép/Communes/Stats")
    print("=" * 55)

    try:
        conn = connect()
    except Exception as e:
        print(f"✗ Connexion impossible : {e}")
        sys.exit(1)

    try:
        df_reg = importer_regions(conn)
        df_dep = importer_departements(conn)
        importer_communes(conn)
        mettre_a_jour_chefs_lieux(conn, df_reg, df_dep)
        importer_type_stats(conn)
        importer_mesures(conn)

        # Vérification
        with conn.cursor() as cur:
            for table in ["REGION", "DEPARTEMENT", "COMMUNES", "TYPE_STAT", "MESURE_COM"]:
                cur.execute(f"SELECT COUNT(*) FROM {table}")
                n = cur.fetchone()[0]
                print(f"  {table:20s} : {n:>8,} lignes")

        print("\n✓ Import terminé avec succès !")
    finally:
        conn.close()


if __name__ == "__main__":
    main()

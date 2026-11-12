"""
03_requetes.py
==============
Trois requêtes bien différentes présentées de façon lisible
pour un non-informaticien.

Requête 1 : Classement des communes d'un département par population
Requête 2 : Évolution de la population d'une région sur plusieurs décennies
Requête 3 : Taux de natalité vs mortalité par département (ratio naissances/décès)
"""

import psycopg
import sys

DB_CONFIG = {
    "host":     "pgsql",
    "dbname":   "soubenachour",
    "user":     "soubenachour",
    "password": "VOTRE_MOT_DE_PASSE"
}


def separateur(titre: str):
    print()
    print("=" * 60)
    print(f"  {titre}")
    print("=" * 60)


# ============================================================
# Requête 1 : Liste des communes de plus de X habitants
#             dans un département donné
# Démo avec la Gironde (33) et seuil 20 000 habitants
# ============================================================
def requete_communes_par_population(cur, code_dep: str = "33", seuil: int = 20_000):
    separateur(f"Top communes du département {code_dep} (>{seuil:,} hab.)")

    # Double jointure : commune -> département -> type_stat
    # On filtre sur l'année la plus récente (2021) et le type POP
    cur.execute("""
        SELECT
            c.nom                    AS commune,
            m.valeur::BIGINT         AS population,
            d.nom                    AS departement,
            r.nom                    AS region
        FROM COMMUNES c
        JOIN DEPARTEMENT d  ON c.id_departement = d.id
        JOIN REGION r       ON d.id_region = r.id
        JOIN MESURE_COM m   ON m.id_commune = c.id
        JOIN TYPE_STAT  ts  ON ts.id = m.id_type
        WHERE d.code_insee = %s
          AND ts.code      = 'POP'
          AND m.annee_debut = 2021
          AND m.valeur >= %s
        ORDER BY m.valeur DESC
    """, (code_dep, seuil))

    rows = cur.fetchall()
    if not rows:
        print("  Aucune commune trouvée.")
        return

    dep_nom = rows[0][2]
    region  = rows[0][3]
    print(f"  Département : {dep_nom} ({code_dep}) — Région : {region}")
    print(f"  {len(rows)} communes de plus de {seuil:,} habitants (recensement 2021)\n")
    print(f"  {'Rang':>4}  {'Commune':<30}  {'Population':>12}")
    print(f"  {'-'*4}  {'-'*30}  {'-'*12}")
    for rang, (commune, pop, _, _) in enumerate(rows, 1):
        print(f"  {rang:>4}.  {commune:<30}  {pop:>12,}")


# ============================================================
# Requête 2 : Évolution démographique d'une région sur les décennies
# Démo avec la Nouvelle-Aquitaine (code INSEE 75)
# ============================================================
def requete_evolution_region(cur, code_reg: str = "75"):
    separateur(f"Évolution de la population — Région {code_reg}")

    cur.execute("""
        SELECT
            r.nom           AS region,
            m.annee_debut   AS annee,
            SUM(mc.valeur)::BIGINT AS population
        FROM REGION r
        JOIN DEPARTEMENT d  ON d.id_region = r.id
        JOIN COMMUNES c     ON c.id_departement = d.id
        JOIN MESURE_COM mc  ON mc.id_commune = c.id
        JOIN TYPE_STAT ts   ON ts.id = mc.id_type
        -- on n'a pas besoin de MESURE_REG ici, on agrège depuis les communes
        JOIN (
            SELECT annee_debut
            FROM MESURE_COM
            WHERE annee_debut = annee_fin   -- seulement les stats ponctuelles
            GROUP BY annee_debut
        ) m ON m.annee_debut = mc.annee_debut
        WHERE r.code_insee = %s
          AND ts.code      = 'POP'
          AND mc.annee_debut = mc.annee_fin
        GROUP BY r.nom, m.annee_debut
        ORDER BY m.annee_debut
    """, (code_reg,))

    rows = cur.fetchall()
    if not rows:
        print("  Aucune donnée.")
        return

    region_nom = rows[0][0]
    print(f"  Région : {region_nom} (code {code_reg})\n")
    print(f"  {'Année':>6}  {'Population':>14}  {'Évolution':>12}")
    print(f"  {'-'*6}  {'-'*14}  {'-'*12}")
    pop_prec = None
    for (nom, annee, pop) in rows:
        if pop_prec and pop_prec > 0:
            evol = f"{(pop - pop_prec) / pop_prec * 100:+.1f} %"
        else:
            evol = "—"
        print(f"  {annee:>6}  {pop:>14,}  {evol:>12}")
        pop_prec = pop


# ============================================================
# Requête 3 : Bilan naturel (naissances - décès) par département
#             pour la période 2015-2020
# ============================================================
def requete_bilan_naturel_departements(cur, code_reg: str = "75"):
    separateur(f"Bilan naturel (2015-2020) — Région {code_reg}")

    cur.execute("""
        SELECT
            d.nom                              AS departement,
            SUM(CASE WHEN ts.code = 'NAIS' THEN mc.valeur ELSE 0 END)::INT AS naissances,
            SUM(CASE WHEN ts.code = 'DEC'  THEN mc.valeur ELSE 0 END)::INT AS deces,
            (SUM(CASE WHEN ts.code = 'NAIS' THEN mc.valeur ELSE 0 END)
           - SUM(CASE WHEN ts.code = 'DEC'  THEN mc.valeur ELSE 0 END))::INT AS bilan
        FROM DEPARTEMENT d
        JOIN REGION r       ON r.id = d.id_region
        JOIN COMMUNES c     ON c.id_departement = d.id
        JOIN MESURE_COM mc  ON mc.id_commune = c.id
        JOIN TYPE_STAT ts   ON ts.id = mc.id_type
        WHERE r.code_insee = %s
          AND ts.code IN ('NAIS', 'DEC')
          AND mc.annee_debut = 2015
          AND mc.annee_fin   = 2020
        GROUP BY d.nom
        ORDER BY bilan DESC
    """, (code_reg,))

    rows = cur.fetchall()
    if not rows:
        print("  Aucune donnée.")
        return

    print(f"  Période analysée : 2015 – 2020")
    print(f"  Un bilan positif = plus de naissances que de décès\n")
    print(f"  {'Département':<25}  {'Naissances':>11}  {'Décès':>9}  {'Bilan':>10}")
    print(f"  {'-'*25}  {'-'*11}  {'-'*9}  {'-'*10}")
    for (dep, nais, dec, bilan) in rows:
        signe = "▲" if bilan >= 0 else "▼"
        print(f"  {dep:<25}  {nais:>11,}  {dec:>9,}  {signe} {bilan:>8,}")


# ============================================================
# MAIN
# ============================================================
def main():
    print("\n╔══════════════════════════════════════════════════════╗")
    print("║   ANALYSE DÉMOGRAPHIQUE — Base INSEE France          ║")
    print("╚══════════════════════════════════════════════════════╝")

    try:
        conn = psycopg.connect(**DB_CONFIG)
    except Exception as e:
        print(f"✗ Connexion impossible : {e}")
        sys.exit(1)

    with conn.cursor() as cur:
        # Requête 1 : communes de Gironde (33) de + 20 000 hab.
        requete_communes_par_population(cur, code_dep="33", seuil=20_000)

        # Requête 2 : évolution de la Nouvelle-Aquitaine (75)
        requete_evolution_region(cur, code_reg="75")

        # Requête 3 : bilan naturel en Nouvelle-Aquitaine
        requete_bilan_naturel_departements(cur, code_reg="75")

    conn.close()
    print("\n✓ Terminé.\n")


if __name__ == "__main__":
    main()

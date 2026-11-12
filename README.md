# Mini-Projet BDD — Base INSEE France

## Structure du projet

```
projet_final/
├── sql/
│   ├── 01_create_tables.sql            ← Création du schéma (DDL)
│   └── 04_vues_procedures_triggers.sql ← Vues, procédures, triggers, EXPLAIN
├── scripts/
│   ├── 02_import_donnees.py            ← Import des CSV avec COPY
│   └── 03_requetes.py                  ← 3 requêtes lisibles
├── data/
│   ├── recensement/                    ← Données INSEE + métadonnées
│   └── referentiels/                   ← Référentiels géographiques (v_*)
└── README.md                           ← Ce fichier
```

## Ordre d'exécution

1. `psql -f sql/01_create_tables.sql`
2. `python scripts/02_import_donnees.py`   (adapter DB_CONFIG)
3. `psql -f sql/04_vues_procedures_triggers.sql`
   → puis `SELECT recalculer_toutes_populations();`
   → puis réactiver les triggers read-only sur REGION/DEPARTEMENT
4. `python scripts/03_requetes.py`

---

## Explication des choix

### Problème circulaire (chef-lieu)

Le problème classique :
- `REGION.id_cheflieu → COMMUNES(id)`
- `COMMUNES.id_departement → DEPARTEMENT(id)`
- `DEPARTEMENT.id_region → REGION(id)`

**Solution** : déclarer les FK chefs-lieux en `DEFERRABLE INITIALLY DEFERRED`.
La contrainte est vérifiée au **commit**, pas à chaque ligne.
Dans `02_import_donnees.py`, on insère REGION et DEPARTEMENT sans chef-lieu
(NULL), on importe COMMUNES avec COPY, puis on UPDATE les chefs-lieux dans
une transaction DEFERRED → le commit final vérifie tout d'un coup.

### COPY vs INSERT

La commande `COPY` de PostgreSQL est 10 à 100× plus rapide que des `INSERT`
individuels car elle contourne les parseurs SQL et écrit directement dans
les pages de données. Pour ~350 000 mesures : quelques secondes au lieu de
plusieurs minutes.

### Statistiques : nouveaux n-uplets uniquement

La table `MESURE_COM` a comme clé primaire `(id_commune, id_type, annee_debut, annee_fin)`.
Ajouter une nouvelle année = ajouter de nouveaux n-uplets.
On ne modifie jamais la structure (pas d'ALTER TABLE ADD COLUMN).

### Triggers read-only sur REGION/DEPARTEMENT

Les triggers `BEFORE INSERT/UPDATE/DELETE` lèvent une exception.
Pour l'import initial (script Python), il faut les désactiver :
```sql
ALTER TABLE REGION      DISABLE TRIGGER ALL;
ALTER TABLE DEPARTEMENT DISABLE TRIGGER ALL;
-- ... import ...
ALTER TABLE REGION      ENABLE TRIGGER ALL;
ALTER TABLE DEPARTEMENT ENABLE TRIGGER ALL;
```

### Calcul automatique en cascade

Quand on insère une mesure de population pour une commune :
1. `trig_maj_pop` appelle `calc_pop_commune(id_commune)`
2. Puis `calc_pop_departement(id_dep)` → ne fait rien si les autres communes ne sont pas encore renseignées
3. Puis `calc_pop_region(id_reg)` → idem

Ainsi, quand on insère la **dernière commune** d'un département, le département
se calcule automatiquement. Et quand le dernier département d'une région est
calculé, la région se calcule à son tour.

---

## Schéma relationnel

```
REGION(id, code_insee, nom, nom_maj, libelle, tncc, #id_cheflieu*, population)
DEPARTEMENT(id, code_insee, nom, nom_maj, libelle, tncc, #id_region, #id_cheflieu*, population)
COMMUNES(id, code_insee, nom, nom_maj, libelle, tncc, #id_departement, population)
TYPE_STAT(id, code, libelle, est_periodique)
MESURE_COM(#id_commune, #id_type, annee_debut, annee_fin, valeur)
MESURE_DEP(#id_departement, #id_type, annee_debut, annee_fin, valeur)
MESURE_REG(#id_region, #id_type, annee_debut, annee_fin, valeur)

* FK DEFERRABLE INITIALLY DEFERRED
```

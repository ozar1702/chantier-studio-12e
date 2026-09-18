# Chantier & Panier — Netlify relié à Supabase

Même application que la v1, mais Netlify et Supabase sont reliés **nativement** : Netlify récupère les clés de votre projet Supabase tout seul, écrit la configuration au moment du déploiement, et héberge en plus une petite fonction serveur qui lit les pages marchandes.

```
Netlify                                  Supabase
  ├── index.html  ← la page               ├── base de données (travaux, panier, échanges, documents)
  ├── config.js   ← écrit au déploiement  ├── comptes par e-mail
  │     à partir des variables posées ────┤
  │     par l'extension Supabase          └── stockage des fichiers
  └── /api/lien   ← fonction : lit une page produit (nom, prix, photo)
                    et vérifie d'abord le jeton de session Supabase
```

## Contenu du dossier

| Chemin | Rôle |
|---|---|
| `index.html` | L'application |
| `config.js` | Réécrit à chaque déploiement ; les valeurs livrées ne servent qu'en local |
| `netlify.toml` | Commande de build, dossier des fonctions, en-têtes |
| `scripts/config-build.mjs` | Fabrique `config.js` depuis les variables d'environnement |
| `netlify/functions/unfurl.mjs` | La fonction `/api/lien` |
| `supabase/01_schema.sql` | Tables, droits, historique, stockage, temps réel |
| `supabase/02_donnees.sql` | Vos données : 96 lignes de travaux, 8 échéances, 76 articles |

## 1. La base Supabase

1. [supabase.com](https://supabase.com) → **New project**, région **Paris** ou **Francfort**.
2. **SQL Editor** → coller `supabase/01_schema.sql` → **Run**.
3. Ouvrir `supabase/02_donnees.sql`, vérifier l'adresse e-mail du client tout en bas → **Run**.

## 2. Le site Netlify

Le lien natif passe par les variables d'environnement : Netlify doit donc **construire** le site. Le glisser-déposer ne construit rien, il faut l'une de ces deux méthodes.

**A. Depuis un dépôt Git** *(recommandé : chaque `git push` redéploie)*
1. Déposer ce dossier dans un dépôt privé GitHub, GitLab ou Bitbucket.
2. Netlify → **Add new project → Import an existing project** → choisir le dépôt.
3. Netlify lit `netlify.toml` : commande `node scripts/config-build.mjs`, publication à la racine. Ne rien changer.

**B. Depuis votre ordinateur, sans Git**
```bash
npm install -g netlify-cli
netlify login
cd chantier-netlify
netlify deploy --build --prod
```

## 3. Relier Supabase à Netlify — l'extension

1. Netlify → **Team settings → Extensions** → chercher **Supabase** → **Install**.
2. Aller sur le site → **Project configuration → General → Supabase** → **Connect**.
3. S'identifier chez Supabase (OAuth), choisir le projet, et pour le framework prendre **Other**.
4. **Save**.

L'extension pose trois variables sur le site : `SUPABASE_DATABASE_URL` (l'adresse du projet), `SUPABASE_ANON_KEY` et `SUPABASE_SERVICE_ROLE_KEY`.

Le script de build n'utilise que les **deux premières** — celles qui peuvent aller dans un navigateur. La clé *service role* ouvre la base en grand et ne quitte jamais Netlify : ni le script ni la page ne la lisent.

Relancez ensuite un déploiement (**Deploys → Trigger deploy**) : le journal doit afficher `✓ config.js écrit pour https://…supabase.co`. S'il affiche l'inverse, c'est que l'extension n'est pas connectée à **ce** site.

> Vous pouvez aussi vous passer de l'extension : **Site configuration → Environment variables**, et créer à la main `SUPABASE_DATABASE_URL` et `SUPABASE_ANON_KEY`. Le script accepte aussi les préfixes `NEXT_PUBLIC_` et `VITE_`.

## 4. Les e-mails de connexion — toujours obligatoire

Supabase n'envoie qu'aux membres de votre équipe Supabase, 2 messages par heure : vos artisans ne recevraient rien.

1. Compte gratuit chez **Brevo** (français) ou **Resend**, récupérer les paramètres SMTP.
2. Supabase → **Authentication → Emails → SMTP Settings** → activer *Custom SMTP*.
3. **Authentication → Emails → Templates** → dans *Magic Link* et *Confirm signup*, garder le lien et ajouter le code :
   ```html
   <p><a href="{{ .ConfirmationURL }}">Se connecter</a></p>
   <p>Ou saisissez ce code sur la page : <strong>{{ .Token }}</strong></p>
   ```

## 5. Déclarer l'adresse du site

Supabase → **Authentication → URL Configuration** :
- *Site URL* : l'adresse Netlify (`https://votre-site.netlify.app`) ;
- *Redirect URLs* : la même adresse. Ajoutez `https://*--votre-site.netlify.app/**` si vous voulez que les aperçus de déploiement fonctionnent aussi.

## 6. Premier test

Ouvrir le site, saisir votre adresse, cliquer le lien reçu ou saisir le code. Puis onglet **Accès** pour inviter un artisan : e-mail, rôle Artisan, entreprise écrite exactement comme dans le tableau (`ISO DECO`). Son fil de discussion se crée automatiquement.

## La fonction `/api/lien`

Le bouton **Récupérer** de la fiche article l'appelle avec le lien de la boutique. Elle télécharge la page, y lit les balises d'aperçu (`og:image`, `og:title`) et la fiche produit structurée (JSON-LD `Product`, `product:price:amount`), et renvoie nom, prix, photo et boutique. Rien n'est accepté en aveugle : tout reste modifiable, et ce qui manque est signalé.

Deux garde-fous, parce qu'une fonction qui va chercher n'importe quelle adresse est une porte ouverte :
- elle **exige un jeton de session Supabase valide**, vérifié auprès de Supabase à chaque appel — un inconnu qui trouve l'adresse `/api/lien` reçoit un refus ;
- elle **refuse les adresses internes** (localhost, 10.x, 192.168.x, `.local`…) et tout ce qui n'est pas http(s), et s'arrête à 1,5 Mo de page.

Testée sur treize cas : fiche produit complète, prix au format français (`1 299,90`), `@graph` imbriqué, page sans prix, image relative, appel sans jeton, jeton invalide, réseau interne, `file://`, site en erreur, lien vers une image, site injoignable, mauvaise méthode.

Ce qu'elle ne peut pas faire : les sites qui n'affichent leur prix qu'après exécution de leur JavaScript, et ceux qui bloquent les robots (Amazon et quelques grandes enseignes). Dans ces cas l'écran bascule en saisie manuelle, ce qui est le comportement prévu.

## Si vous préférez rester au glisser-déposer

Ouvrez `config.js`, remplacez les deux valeurs par celles de **Supabase → Project Settings → API**, mettez `unfurl: ""`, et déposez le dossier sur [app.netlify.com/drop](https://app.netlify.com/drop). Vous perdez la mise à jour automatique des clés et la lecture des liens ; tout le reste fonctionne.

## Coûts

- Supabase : offre gratuite suffisante ; un projet gratuit est mis en pause après une semaine sans activité (l'offre Pro, à partir de 25 $/mois, l'évite et ajoute des sauvegardes).
- Netlify : offre gratuite suffisante — 300 minutes de build et 125 000 appels de fonction par mois, très au-delà de cet usage.
- Brevo ou Resend : offre gratuite suffisante.

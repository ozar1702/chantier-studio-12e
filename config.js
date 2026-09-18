/* Réécrit à chaque déploiement par scripts/config-build.mjs.
   Ces valeurs ne servent qu'en local, ou si vous choisissez le glisser-déposer :
   remplacez-les alors par celles de Supabase → Project Settings → API. */
window.SUIVI_CONFIG = {
  supabaseUrl: "https://VOTRE-PROJET.supabase.co",
  supabaseAnonKey: "VOTRE-CLE-ANON-PUBLIC",
  google: false,
  unfurl: "/api/lien"
};

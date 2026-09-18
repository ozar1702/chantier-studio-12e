/**
 * Écrit config.js à partir des variables d'environnement Netlify.
 * Ces variables sont posées automatiquement par l'extension Supabase
 * (Netlify : Team settings → Extensions → Supabase, puis Connect sur le site).
 *
 * Lancé par la commande de build déclarée dans netlify.toml.
 */
import {writeFileSync, existsSync, readFileSync} from "node:fs";

const env = process.env;
const url =
  env.SUPABASE_DATABASE_URL || env.SUPABASE_URL ||
  env.NEXT_PUBLIC_SUPABASE_URL || env.VITE_SUPABASE_URL || "";
const anon =
  env.SUPABASE_ANON_KEY ||
  env.NEXT_PUBLIC_SUPABASE_ANON_KEY || env.VITE_SUPABASE_ANON_KEY || "";
const google = /^(1|true|oui|yes)$/i.test(env.CHANTIER_GOOGLE || "");

const dejaRenseigne = () => {
  if (!existsSync("config.js")) return false;
  const t = readFileSync("config.js", "utf8");
  return /supabaseUrl:\s*"https:\/\/[a-z0-9-]+\.supabase\.co"/i.test(t) && !/VOTRE/i.test(t);
};

if (!url || !anon) {
  if (dejaRenseigne()) {
    console.log("• Extension Supabase absente, mais config.js contient déjà des valeurs : on le garde tel quel.");
    process.exit(0);
  }
  console.error([
    "",
    "✗ Impossible de construire config.js : les clés Supabase manquent.",
    "",
    "  Deux façons de les fournir :",
    "  1. Extension Supabase (recommandé) — dans Netlify :",
    "     Team settings → Extensions → Supabase → Install,",
    "     puis sur le site : Project configuration → General → Supabase → Connect.",
    "     Elle pose SUPABASE_DATABASE_URL et SUPABASE_ANON_KEY toute seule.",
    "  2. À la main — Site configuration → Environment variables :",
    "     SUPABASE_DATABASE_URL = https://xxxx.supabase.co",
    "     SUPABASE_ANON_KEY     = eyJ...",
    "",
  ].join("\n"));
  process.exit(1);
}

if (!/^https:\/\/[a-z0-9-]+\.supabase\.(co|in)\/?$/i.test(url)) {
  console.error(`✗ SUPABASE_DATABASE_URL ne ressemble pas à l'adresse d'un projet Supabase : ${url}`);
  console.error("  Attendu : https://xxxx.supabase.co (et non la chaîne de connexion PostgreSQL).");
  process.exit(1);
}
if (anon.split(".").length < 3) {
  console.error("✗ SUPABASE_ANON_KEY ne ressemble pas à une clé « anon public ».");
  process.exit(1);
}

const contenu = `/* Généré au déploiement par scripts/config-build.mjs — ne pas modifier à la main. */
window.SUIVI_CONFIG = {
  supabaseUrl: ${JSON.stringify(url.replace(/\/$/, ""))},
  supabaseAnonKey: ${JSON.stringify(anon)},
  google: ${google},
  unfurl: "/api/lien"
};
`;
writeFileSync("config.js", contenu);
console.log(`✓ config.js écrit pour ${url.replace(/\/$/, "")}${google ? " (connexion Google activée)" : ""}`);

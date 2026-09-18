/**
 * Lecture d'une page marchande : renvoie { nom, prix, image, boutique }.
 * Appelée par le bouton « Récupérer » de la fiche article.
 *
 * Deux garde-fous :
 *  - l'appelant doit présenter un jeton de session Supabase valide ;
 *  - seules les adresses publiques en http(s) sont lues (pas de réseau interne).
 */

const SUPABASE_URL = process.env.SUPABASE_DATABASE_URL || process.env.SUPABASE_URL || "";
const SUPABASE_ANON = process.env.SUPABASE_ANON_KEY || "";
const TAILLE_MAX = 1_500_000;   // 1,5 Mo de HTML suffisent largement
const DELAI = 9000;

const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: {"content-type": "application/json; charset=utf-8", "cache-control": "no-store"},
  });

/* ---------- l'appelant est-il connecté au chantier ? ---------- */
async function connecte(req) {
  if (!SUPABASE_URL || !SUPABASE_ANON) return false;      // extension non branchée : on refuse
  const auth = req.headers.get("authorization") || "";
  if (!/^Bearer \S+$/.test(auth)) return false;
  try {
    const r = await fetch(`${SUPABASE_URL.replace(/\/$/, "")}/auth/v1/user`, {
      headers: {Authorization: auth, apikey: SUPABASE_ANON},
    });
    return r.ok;
  } catch { return false; }
}

/* ---------- adresse acceptable ? ---------- */
const PRIVE = /^(localhost$|127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|\[?::1\]?$|.*\.local$|.*\.internal$)/i;
function adresseOk(u) {
  let url;
  try { url = new URL(u); } catch { return null; }
  if (!/^https?:$/.test(url.protocol)) return null;
  if (PRIVE.test(url.hostname)) return null;
  if (url.hostname.indexOf(".") < 0) return null;
  return url;
}

/* ---------- extraction ---------- */
const decode = t => String(t || "")
  .replace(/&(#\d+|#x[0-9a-f]+|[a-z]+);/gi, (m, e) => {
    if (e[0] === "#") return String.fromCodePoint(parseInt(e[1] === "x" || e[1] === "X" ? e.slice(2) : e.slice(1), e[1] === "x" || e[1] === "X" ? 16 : 10));
    return {amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ", eacute: "é", egrave: "è", agrave: "à", ccedil: "ç", ocirc: "ô", ecirc: "ê"}[e.toLowerCase()] || m;
  })
  .replace(/\s+/g, " ").trim();

function meta(html, prop) {
  const re = new RegExp(`<meta[^>]+(?:property|name|itemprop)=["']${prop}["'][^>]*>`, "i");
  const tag = (html.match(re) || [])[0];
  if (!tag) return "";
  const c = tag.match(/content=["']([^"']*)["']/i);
  return c ? decode(c[1]) : "";
}

function nombre(v) {
  if (v == null) return null;
  let t = String(v).replace(/\s| |&nbsp;/g, "");
  if (/,\d{1,2}$/.test(t)) t = t.replace(/\./g, "").replace(",", ".");   // 1.299,90 → 1299.90
  else t = t.replace(/,/g, "");
  const n = parseFloat(t.replace(/[^\d.]/g, ""));
  return Number.isFinite(n) && n >= 0 && n < 1e7 ? Math.round(n * 100) / 100 : null;
}

function jsonLd(html) {
  const out = {};
  const blocs = html.match(/<script[^>]+application\/ld\+json[^>]*>([\s\S]*?)<\/script>/gi) || [];
  for (const b of blocs) {
    const brut = b.replace(/^[\s\S]*?>/, "").replace(/<\/script>$/i, "");
    let data; try { data = JSON.parse(brut); } catch { continue; }
    const pile = Array.isArray(data) ? [...data] : [data];
    while (pile.length) {
      const n = pile.shift();
      if (!n || typeof n !== "object") continue;
      if (Array.isArray(n["@graph"])) pile.push(...n["@graph"]);
      const type = [].concat(n["@type"] || []).join(" ");
      if (!/Product/i.test(type)) continue;
      if (!out.nom && typeof n.name === "string") out.nom = decode(n.name);
      if (!out.image) {
        const im = Array.isArray(n.image) ? n.image[0] : n.image;
        if (typeof im === "string") out.image = im;
        else if (im && typeof im.url === "string") out.image = im.url;
      }
      const offres = [].concat(n.offers || []);
      for (const o of offres) {
        if (!o || typeof o !== "object") continue;
        const p = nombre(o.price ?? (o.priceSpecification && o.priceSpecification.price));
        if (p != null && out.prix == null) out.prix = p;
      }
    }
  }
  return out;
}

export default async (req) => {
  if (req.method !== "GET") return json({erreur: "méthode"}, 405);
  if (!(await connecte(req))) return json({erreur: "non autorisé"}, 401);

  const url = adresseOk(new URL(req.url).searchParams.get("u") || "");
  if (!url) return json({erreur: "adresse invalide"}, 400);

  const stop = AbortSignal.timeout ? AbortSignal.timeout(DELAI) : undefined;
  let html = "";
  try {
    const r = await fetch(url.href, {
      signal: stop,
      redirect: "follow",
      headers: {
        "user-agent": "Mozilla/5.0 (compatible; ChantierPanier/1.0; aperçu de lien)",
        "accept": "text/html,application/xhtml+xml",
        "accept-language": "fr-FR,fr;q=0.9",
      },
    });
    if (!r.ok) return json({erreur: "page inaccessible", statut: r.status}, 502);
    const type = r.headers.get("content-type") || "";
    if (!/html/i.test(type)) return json({erreur: "ce lien ne renvoie pas une page web"}, 415);
    const buf = await r.arrayBuffer();
    html = new TextDecoder("utf-8").decode(buf.slice(0, TAILLE_MAX));
  } catch (e) {
    return json({erreur: "lecture impossible", detail: String(e && e.message || e)}, 502);
  }

  const ld = jsonLd(html);
  const titre = (html.match(/<title[^>]*>([\s\S]*?)<\/title>/i) || [])[1];
  const nom = ld.nom || meta(html, "og:title") || decode(titre) || "";
  const prix = ld.prix
    ?? nombre(meta(html, "product:price:amount"))
    ?? nombre(meta(html, "og:price:amount"))
    ?? nombre(meta(html, "price"))
    ?? null;
  let image = ld.image || meta(html, "og:image") || meta(html, "twitter:image") || "";
  if (image && !/^https?:/i.test(image)) { try { image = new URL(image, url.href).href; } catch { image = ""; } }

  return json({
    nom: nom.slice(0, 160),
    prix,
    image,
    boutique: (meta(html, "og:site_name") || url.hostname.replace(/^www\./, "")).slice(0, 60),
    source: url.href,
  });
};

export const config = {path: "/api/lien"};

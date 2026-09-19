-- =====================================================================
-- Chantier & Panier — schéma Supabase (v1, quatre espaces)
-- À exécuter dans Supabase > SQL Editor. Le script peut être relancé.
-- =====================================================================

-- ---------- Accès ----------
-- role = 'client'  : voit et modifie tout.
-- role = 'artisan' : uniquement les travaux de son entreprise, ses paiements,
--                    son fil de discussion et les documents qu'on lui partage.
create table if not exists public.acces (
  email       text primary key check (email = lower(email)),
  role        text not null check (role in ('client', 'artisan')),
  entreprise  text,
  nom         text,
  created_at  timestamptz not null default now(),
  constraint artisan_a_une_entreprise check (role = 'client' or coalesce(entreprise, '') <> '')
);

create or replace function public.email_courant()
returns text language sql stable
as $$ select lower(coalesce(auth.jwt() ->> 'email', '')) $$;

create or replace function public.role_courant()
returns text language sql stable security definer set search_path = public
as $$ select a.role from public.acces a where a.email = public.email_courant() $$;

create or replace function public.entreprise_courante()
returns text language sql stable security definer set search_path = public
as $$ select a.entreprise from public.acces a where a.email = public.email_courant() $$;

create or replace function public.est_client()
returns boolean language sql stable security definer set search_path = public
as $$ select coalesce(public.role_courant() = 'client', false) $$;

-- Ligne visible / modifiable par l'utilisateur connecté ?
create or replace function public.peut_voir(ent text)
returns boolean language sql stable security definer set search_path = public
as $$ select public.est_client() or (public.role_courant() = 'artisan' and ent = public.entreprise_courante()) $$;

grant execute on function public.email_courant(), public.role_courant(), public.entreprise_courante(),
  public.est_client(), public.peut_voir(text) to authenticated;

alter table public.acces enable row level security;
drop policy if exists acces_lecture on public.acces;
create policy acces_lecture on public.acces for select to authenticated
  using (email = public.email_courant() or public.est_client());
drop policy if exists acces_gestion on public.acces;
create policy acces_gestion on public.acces for all to authenticated
  using (public.est_client()) with check (public.est_client());

-- Seules les adresses présentes dans « acces » peuvent créer un compte.
create or replace function public.verifier_inscription()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if not exists (select 1 from public.acces a where a.email = lower(new.email)) then
    raise exception 'Adresse non autorisée pour ce chantier.';
  end if;
  return new;
end;
$$;
drop trigger if exists avant_inscription on auth.users;
create trigger avant_inscription before insert on auth.users
  for each row execute function public.verifier_inscription();

-- ---------- Chantier ----------
create table if not exists public.config (
  id    text primary key,
  data  jsonb not null default '{}'::jsonb
);
alter table public.config enable row level security;
drop policy if exists config_lecture on public.config;
create policy config_lecture on public.config for select to authenticated
  using (public.role_courant() is not null);
drop policy if exists config_ecriture on public.config;
create policy config_ecriture on public.config for all to authenticated
  using (public.est_client()) with check (public.est_client());

-- ---------- Espace 1 · Travaux ----------
create table if not exists public.travaux (
  id                  text primary key,
  ordre               integer not null default 0,
  phase               text not null default '',
  entreprise          text not null default '',
  piece               text not null default '',
  type                text not null default '',
  travaux             text not null,
  devis               text not null default 'Non Inclus' check (devis in ('Inclus', 'Non Inclus', 'NC')),
  statut              text not null default 'A initier',
  artisan             text not null default '',
  quantite            numeric,
  unite               text not null default '',
  prix_ttc            numeric,
  fourniture_requise  boolean not null default false,
  fourniture          numeric,
  commentaire         text not null default '',
  heures              numeric,
  reduction           numeric,
  debut               date,
  fin                 date,
  devis_source        text not null default '',
  photo               text not null default '',  -- chemin dans le seau « photos », mis en pièce jointe au message auto de fin de tâche
  updated_at          timestamptz not null default now(),
  updated_by          text,
  constraint dates_ordonnees check (debut is null or fin is null or fin >= debut)
);
alter table public.travaux add column if not exists photo text not null default '';
create index if not exists travaux_entreprise_idx on public.travaux (entreprise);

alter table public.travaux enable row level security;
drop policy if exists travaux_lecture on public.travaux;
create policy travaux_lecture on public.travaux for select to authenticated
  using (public.peut_voir(entreprise));
drop policy if exists travaux_creation on public.travaux;
create policy travaux_creation on public.travaux for insert to authenticated
  with check (public.peut_voir(entreprise));
drop policy if exists travaux_modification on public.travaux;
create policy travaux_modification on public.travaux for update to authenticated
  using (public.peut_voir(entreprise)) with check (public.peut_voir(entreprise));
drop policy if exists travaux_suppression on public.travaux;
create policy travaux_suppression on public.travaux for delete to authenticated
  using (public.peut_voir(entreprise));

-- ---------- Paiements ----------
create table if not exists public.paiements (
  id             text primary key,
  ordre          integer not null default 0,
  entreprise     text not null,
  devis_source   text not null default '',  -- vide = devis principal ; sinon doit reprendre une valeur de travaux.devis_source
  libelle        text not null,
  mode           text not null default 'pct' check (mode in ('pct', 'montant')),
  valeur         numeric not null default 0,
  paye           boolean not null default false,
  date_paiement  date,
  updated_at     timestamptz not null default now(),
  updated_by     text
);
alter table public.paiements add column if not exists devis_source text not null default '';
alter table public.paiements enable row level security;
drop policy if exists paiements_lecture on public.paiements;
create policy paiements_lecture on public.paiements for select to authenticated
  using (public.peut_voir(entreprise));
drop policy if exists paiements_ecriture on public.paiements;
create policy paiements_ecriture on public.paiements for all to authenticated
  using (public.est_client()) with check (public.est_client());

-- ---------- Espace 2 · Panier d'ameublement (client uniquement) ----------
create table if not exists public.ameublement (
  id              text primary key,
  ordre           integer not null default 0,
  categorie       text not null default 'Divers',
  piece           text not null default '',
  nom             text not null,
  modele          text not null default '',
  lien            text not null default '',
  fournisseur     text not null default '',
  prix            numeric,
  quantite        numeric not null default 1,
  statut          text not null default 'À initier',
  pose            text not null default '',
  delai           numeric,
  date_commande   date,
  date_livraison  date,
  image           text not null default '',
  commentaire     text not null default '',
  updated_at      timestamptz not null default now(),
  updated_by      text,
  constraint lien_http check (lien = '' or lien ~* '^https?://')
);
alter table public.ameublement enable row level security;
drop policy if exists ameublement_client on public.ameublement;
create policy ameublement_client on public.ameublement for all to authenticated
  using (public.est_client()) with check (public.est_client());

-- ---------- Espace 3 · Échanges ----------
-- Un fil par entreprise, plus le carnet privé du client (entreprise vide).
create table if not exists public.fils (
  id          text primary key,
  ordre       integer not null default 0,
  nom         text not null,
  entreprise  text not null default '',
  prive       boolean not null default false,
  general     boolean not null default false,  -- vu par le client ET tous les artisans à la fois
  created_at  timestamptz not null default now()
);
alter table public.fils add column if not exists general boolean not null default false;
alter table public.fils enable row level security;
drop policy if exists fils_lecture on public.fils;
create policy fils_lecture on public.fils for select to authenticated
  using (case when prive then public.est_client()
              when general then public.role_courant() is not null
              else public.peut_voir(entreprise) end);
drop policy if exists fils_gestion on public.fils;
create policy fils_gestion on public.fils for all to authenticated
  using (public.est_client()) with check (public.est_client());

create table if not exists public.messages (
  id          bigint generated always as identity primary key,
  fil         text not null references public.fils(id) on delete cascade,
  at          timestamptz not null default now(),
  email       text,
  auteur      text not null default '',
  texte       text not null default '',
  ref         text,                       -- ligne de travaux ou article cité
  piece_jointe text not null default '',  -- chemin dans le seau « documents »
  lu_client   boolean not null default false,
  lu_artisan  boolean not null default false
);
create index if not exists messages_fil_idx on public.messages (fil, at);

-- Le fil décide qui voit ses messages.
create or replace function public.fil_visible(f text)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.fils x
     where x.id = f
       and (case when x.prive then public.est_client()
                 when x.general then public.role_courant() is not null
                 else public.peut_voir(x.entreprise) end))
$$;
grant execute on function public.fil_visible(text) to authenticated;

alter table public.messages enable row level security;
drop policy if exists messages_lecture on public.messages;
create policy messages_lecture on public.messages for select to authenticated
  using (public.fil_visible(fil));
drop policy if exists messages_envoi on public.messages;
create policy messages_envoi on public.messages for insert to authenticated
  with check (public.fil_visible(fil) and email = public.email_courant());
drop policy if exists messages_maj on public.messages;
create policy messages_maj on public.messages for update to authenticated
  using (public.fil_visible(fil)) with check (public.fil_visible(fil));
-- pas de suppression : un message envoyé reste au dossier

-- ---------- Message automatique de fin de tâche ----------
-- Quand une ligne de travaux passe au statut « Fait », un message est posté
-- automatiquement dans le fil marqué « general » (voir table fils), avec la
-- photo de la ligne en pièce jointe si elle existe.
create or replace function public.annoncer_fin_travaux()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  fil_general text;
  nom_auteur  text;
begin
  if new.statut = 'Fait' and coalesce(old.statut, '') is distinct from 'Fait' then
    select id into fil_general from public.fils where general limit 1;
    if fil_general is not null then
      select a.nom into nom_auteur from public.acces a where a.email = public.email_courant();
      insert into public.messages (fil, email, auteur, texte, ref, piece_jointe)
      values (fil_general, nullif(public.email_courant(), ''),
              coalesce(nom_auteur, public.entreprise_courante(), 'Système'),
              new.travaux || ' réalisé', new.id, coalesce(new.photo, ''));
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists travaux_annonce on public.travaux;
create trigger travaux_annonce after update on public.travaux
  for each row execute function public.annoncer_fin_travaux();

-- ---------- Espace 4 · Documents ----------
create table if not exists public.documents (
  id          text primary key,
  nom         text not null,
  cat         text not null default 'Administratif',
  date_doc    date,
  taille      bigint not null default 0,
  note        text not null default '',
  chemin      text not null default '',      -- chemin dans le seau « documents »
  partage     text[] not null default '{}',  -- entreprises autorisées
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  updated_by  text
);
alter table public.documents enable row level security;
drop policy if exists documents_lecture on public.documents;
create policy documents_lecture on public.documents for select to authenticated
  using (public.est_client() or public.entreprise_courante() = any (partage));
drop policy if exists documents_gestion on public.documents;
create policy documents_gestion on public.documents for all to authenticated
  using (public.est_client()) with check (public.est_client());

-- ---------- Horodatage ----------
create or replace function public.horodater()
returns trigger language plpgsql
as $$
begin
  new.updated_at := now();
  new.updated_by := nullif(public.email_courant(), '');
  return new;
end;
$$;
do $$
declare t text;
begin
  foreach t in array array['travaux', 'paiements', 'ameublement', 'documents'] loop
    execute format('drop trigger if exists %I_horodatage on public.%I', t, t);
    execute format('create trigger %I_horodatage before insert or update on public.%I
                    for each row execute function public.horodater()', t, t);
  end loop;
end $$;

-- ---------- Journal des modifications ----------
create table if not exists public.journal (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  email       text,
  table_nom   text not null,
  ligne_id    text not null,
  entreprise  text,
  action      text not null,
  libelle     text,
  changements jsonb
);
create index if not exists journal_at_idx on public.journal (at desc);
alter table public.journal enable row level security;
drop policy if exists journal_lecture on public.journal;
create policy journal_lecture on public.journal for select to authenticated
  using (case when table_nom in ('ameublement', 'documents') then public.est_client()
              else public.peut_voir(entreprise) end);
-- aucune écriture directe : seul le déclencheur ci-dessous alimente le journal

create or replace function public.journaliser()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  avant jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) - 'updated_at' - 'updated_by' end;
  apres jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) - 'updated_at' - 'updated_by' end;
  diff  jsonb;
  ref   jsonb := coalesce(apres, avant);
begin
  if tg_op = 'UPDATE' then
    select coalesce(jsonb_object_agg(k, jsonb_build_object('avant', avant -> k, 'apres', apres -> k)), '{}'::jsonb)
      into diff
      from jsonb_object_keys(apres) k
     where (avant -> k) is distinct from (apres -> k);
    if diff = '{}'::jsonb then return new; end if;
  elsif tg_op = 'INSERT' then
    diff := apres;
  else
    diff := avant;
  end if;
  insert into public.journal (email, table_nom, ligne_id, entreprise, action, libelle, changements)
  values (nullif(public.email_courant(), ''), tg_table_name, ref ->> 'id', ref ->> 'entreprise',
          case tg_op when 'INSERT' then 'création' when 'UPDATE' then 'modification' else 'suppression' end,
          coalesce(ref ->> 'travaux', ref ->> 'libelle', ref ->> 'nom'), diff);
  return coalesce(new, old);
end;
$$;
do $$
declare t text;
begin
  foreach t in array array['travaux', 'paiements', 'ameublement', 'documents'] loop
    execute format('drop trigger if exists %I_journal on public.%I', t, t);
    execute format('create trigger %I_journal after insert or update or delete on public.%I
                    for each row execute function public.journaliser()', t, t);
  end loop;
end $$;

-- ---------- Droits de base ----------
grant select, insert, update, delete on public.travaux, public.paiements, public.ameublement,
  public.documents, public.fils, public.config, public.acces to authenticated;
grant select, insert, update on public.messages to authenticated;
grant usage, select on sequence public.messages_id_seq to authenticated;
grant select on public.journal to authenticated;

-- ---------- Fichiers ----------
-- « documents » : privé, lecture par lien signé (le client, et l'artisan pour ce qui lui est partagé).
-- « photos »    : public en lecture (photos d'articles du panier, adresses non devinables).
insert into storage.buckets (id, name, public, file_size_limit)
values ('documents', 'documents', false, 52428800)
on conflict (id) do update set public = false, file_size_limit = 52428800;
insert into storage.buckets (id, name, public, file_size_limit)
values ('photos', 'photos', true, 5242880)
on conflict (id) do update set public = true, file_size_limit = 5242880;

drop policy if exists docs_lecture on storage.objects;
create policy docs_lecture on storage.objects for select to authenticated
  using (bucket_id = 'documents' and (
    public.est_client()
    or exists (select 1 from public.documents d
                where d.chemin = name and public.entreprise_courante() = any (d.partage))));
drop policy if exists docs_depot on storage.objects;
create policy docs_depot on storage.objects for insert to authenticated
  with check (bucket_id = 'documents' and public.est_client());
drop policy if exists docs_maj on storage.objects;
create policy docs_maj on storage.objects for update to authenticated
  using (bucket_id = 'documents' and public.est_client());
drop policy if exists docs_suppression on storage.objects;
create policy docs_suppression on storage.objects for delete to authenticated
  using (bucket_id = 'documents' and public.est_client());

drop policy if exists photos_lecture on storage.objects;
create policy photos_lecture on storage.objects for select to public
  using (bucket_id = 'photos');
drop policy if exists photos_ecriture on storage.objects;
create policy photos_ecriture on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and public.role_courant() is not null);
drop policy if exists photos_suppression on storage.objects;
create policy photos_suppression on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and public.est_client());

-- ---------- Temps réel ----------
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['travaux', 'paiements', 'ameublement', 'documents', 'messages', 'fils', 'journal'] loop
      if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

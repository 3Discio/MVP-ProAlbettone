-- =====================================================================
-- RICORSI SULLE MULTE
-- Da eseguire su Supabase (SQL Editor → incolla → Run) DOPO multe.sql.
-- Si può rieseguire senza problemi.
--
-- Regole:
--   • Chi ha preso una multa (approvata e non ancora pagata) può fare ricorso
--     una volta sola, scrivendo la motivazione. Il giudice no: non può
--     contestare le proprie multe.
--   • Finché il ricorso è in attesa la scadenza è sospesa (la multa non può
--     raddoppiare per il ritardo) e il tesoriere non la incassa.
--   • Il giudice risponde sempre con una motivazione:
--       - ricorso ACCOLTO  → la multa viene annullata;
--       - ricorso RESPINTO → l'importo raddoppia (×2) e la scadenza riparte
--         da dove si era fermata (si allunga dei giorni passati in attesa).
--   • I raddoppi si sommano: ricorso respinto ×2 e, se poi non viene pagata
--     entro la scadenza, ancora ×2 (quindi fino a ×4).
--   • Chi ha fatto ricorso può ritirarlo finché è in attesa: la multa torna
--     com'era, con la scadenza di prima.
-- =====================================================================

alter table public.fines add column if not exists appeal_status text;
alter table public.fines add column if not exists appeal_reason text;
alter table public.fines add column if not exists appeal_at timestamptz;
alter table public.fines add column if not exists appeal_by uuid;
alter table public.fines add column if not exists appeal_by_name text;
alter table public.fines add column if not exists appeal_due_on date;          -- scadenza sospesa durante il ricorso
alter table public.fines add column if not exists appeal_reply text;
alter table public.fines add column if not exists appeal_decided_at timestamptz;
alter table public.fines add column if not exists appeal_decided_by uuid;
alter table public.fines add column if not exists appeal_decided_by_name text;
alter table public.fines add column if not exists appeal_base_amount numeric;  -- importo prima del raddoppio per ricorso respinto

alter table public.fines drop constraint if exists fines_appeal_status_check;
alter table public.fines add constraint fines_appeal_status_check
  check (appeal_status is null or appeal_status in ('pending', 'accepted', 'rejected'));

-- Presentare un ricorso (lo fa chi ha preso la multa)
create or replace function public.fine_appeal(p_fine uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare f public.fines%rowtype; r text := btrim(coalesce(p_reason, ''));
begin
  if auth.uid() is null then raise exception 'Devi essere connesso.'; end if;
  if length(r) < 5 then raise exception 'Scrivi la motivazione del ricorso.'; end if;
  select * into f from public.fines where id = p_fine for update;
  if not found then raise exception 'Multa non trovata.'; end if;
  if not (f.profile_id = auth.uid()
          or exists (select 1 from public.players p where p.id = f.player_id and p.profile_id = auth.uid())) then
    raise exception 'Puoi fare ricorso solo sulle tue multe.';
  end if;
  if exists (select 1 from public.profiles where id = auth.uid() and is_judge) then
    raise exception 'Il giudice non può fare ricorso sulle proprie multe.';
  end if;
  if f.status <> 'approved' then raise exception 'Si può fare ricorso solo su una multa da pagare.'; end if;
  if f.appeal_status is not null then raise exception 'Su questa multa hai già fatto ricorso.'; end if;
  update public.fines set
    appeal_status = 'pending', appeal_reason = r, appeal_at = now(), appeal_by = auth.uid(),
    appeal_by_name = (select display_name from public.profiles where id = auth.uid()),
    appeal_due_on = f.due_on, due_on = null
  where id = p_fine;
end $$;

-- Ritirare il proprio ricorso finché è in attesa
create or replace function public.fine_appeal_withdraw(p_fine uuid)
returns void language plpgsql security definer set search_path = public as $$
declare f public.fines%rowtype;
begin
  select * into f from public.fines where id = p_fine for update;
  if not found then raise exception 'Multa non trovata.'; end if;
  if f.appeal_status is distinct from 'pending' then raise exception 'Non c''è un ricorso in attesa su questa multa.'; end if;
  if f.appeal_by is distinct from auth.uid() then raise exception 'Può ritirarlo solo chi l''ha presentato.'; end if;
  update public.fines set
    due_on = f.appeal_due_on, appeal_status = null, appeal_reason = null, appeal_at = null,
    appeal_by = null, appeal_by_name = null, appeal_due_on = null
  where id = p_fine;
end $$;

-- Decidere un ricorso (giudice): p_ok = true accoglie (multa annullata), false respinge (importo ×2)
create or replace function public.fine_appeal_decide(p_fine uuid, p_ok boolean, p_reply text)
returns void language plpgsql security definer set search_path = public as $$
declare f public.fines%rowtype; r text := btrim(coalesce(p_reply, ''));
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and is_judge) then
    raise exception 'Solo il giudice decide i ricorsi.';
  end if;
  if length(r) < 2 then raise exception 'Scrivi la risposta al ricorso.'; end if;
  select * into f from public.fines where id = p_fine for update;
  if not found then raise exception 'Multa non trovata.'; end if;
  if f.appeal_status is distinct from 'pending' or f.status <> 'approved' then
    raise exception 'Questo ricorso è già stato deciso.';
  end if;
  update public.fines set
    appeal_status = case when p_ok then 'accepted' else 'rejected' end,
    status = case when p_ok then 'cancelled' else status end,
    appeal_base_amount = case when p_ok then null else f.amount end,
    amount = case when p_ok then f.amount else f.amount * 2 end,
    -- respinto: la scadenza riparte, allungata dei giorni passati in attesa del giudice
    due_on = case when p_ok or f.appeal_due_on is null then null
                  else f.appeal_due_on + greatest(current_date - (f.appeal_at at time zone 'Europe/Rome')::date, 0) end,
    appeal_reply = r, appeal_decided_at = now(), appeal_decided_by = auth.uid(),
    appeal_decided_by_name = (select display_name from public.profiles where id = auth.uid())
  where id = p_fine;
end $$;

revoke all on function public.fine_appeal(uuid, text) from public, anon;
revoke all on function public.fine_appeal_withdraw(uuid) from public, anon;
revoke all on function public.fine_appeal_decide(uuid, boolean, text) from public, anon;
grant execute on function public.fine_appeal(uuid, text) to authenticated;
grant execute on function public.fine_appeal_withdraw(uuid) to authenticated;
grant execute on function public.fine_appeal_decide(uuid, boolean, text) to authenticated;

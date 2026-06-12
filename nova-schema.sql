-- ════════════════════════════════════════════════════════════════
-- NOVA HD · Schema database (Supabase)
-- Come usarlo: dashboard Supabase → SQL Editor → incolla tutto → Run
-- ════════════════════════════════════════════════════════════════

create extension if not exists pgcrypto;

-- ── Impostazioni dello studio (una riga per coach) ──
create table if not exists coach_settings (
  id uuid primary key references auth.users(id) on delete cascade,
  studio text not null default 'NOVA HD',
  color text not null default '#e3b864',
  ai_endpoint text default '',
  app_url text default '',
  booking_enabled boolean not null default false,
  booking_url text default '',          -- fallback esterno (es. Calendly) se booking_enabled = false
  slot_minutes int not null default 60,
  availability jsonb not null default '{}'::jsonb,  -- {"1":{"on":true,"from":"09:00","to":"18:00"}, ...} 0=domenica
  updated_at timestamptz not null default now()
);

-- ── Clienti ──
create table if not exists clients (
  id uuid primary key default gen_random_uuid(),
  coach_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  email text default '',
  birth_date date not null,
  birth_time text not null,             -- "HH:MM"
  tz numeric not null default 1,
  notes text default '',
  summary text default '',
  share_token text unique not null default encode(gen_random_bytes(16),'hex'),
  created_at timestamptz not null default now()
);
create index if not exists clients_coach_idx on clients(coach_id);

-- ── Prenotazioni ──
create table if not exists bookings (
  id uuid primary key default gen_random_uuid(),
  coach_id uuid not null references auth.users(id) on delete cascade,
  client_id uuid not null references clients(id) on delete cascade,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'confermata',   -- confermata | annullata
  note text default '',
  created_at timestamptz not null default now()
);
create index if not exists bookings_coach_idx on bookings(coach_id, starts_at);

-- ── Sicurezza: ogni coach vede solo i propri dati ──
alter table coach_settings enable row level security;
alter table clients enable row level security;
alter table bookings enable row level security;

create policy "coach gestisce le proprie impostazioni" on coach_settings
  for all using (auth.uid() = id) with check (auth.uid() = id);
create policy "coach gestisce i propri clienti" on clients
  for all using (auth.uid() = coach_id) with check (auth.uid() = coach_id);
create policy "coach gestisce le proprie prenotazioni" on bookings
  for all using (auth.uid() = coach_id) with check (auth.uid() = coach_id);

-- ════════════════════════════════════════════════════════════════
-- Funzioni pubbliche per l'APP CLIENTE (accesso solo via share_token)
-- security definer: bypassano la RLS ma espongono solo il necessario
-- ════════════════════════════════════════════════════════════════

-- Carta + branding del coach a partire dal token del link
create or replace function public.get_client_by_token(p_token text)
returns json language sql security definer set search_path = public as $$
  select json_build_object(
    'name', c.name,
    'birth_date', c.birth_date,
    'birth_time', c.birth_time,
    'tz', c.tz,
    'coach', json_build_object(
      'studio', s.studio, 'color', s.color, 'ai_endpoint', s.ai_endpoint,
      'booking_enabled', s.booking_enabled, 'booking_url', s.booking_url,
      'slot_minutes', s.slot_minutes, 'availability', s.availability))
  from clients c
  join coach_settings s on s.id = c.coach_id
  where c.share_token = p_token;
$$;

-- Slot occupati del coach (solo orari, nessun dato personale)
create or replace function public.get_busy_slots(p_token text, p_from timestamptz, p_to timestamptz)
returns json language sql security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('s', b.starts_at, 'e', b.ends_at)), '[]'::json)
  from bookings b
  join clients c on c.coach_id = b.coach_id
  where c.share_token = p_token
    and b.status <> 'annullata'
    and b.starts_at < p_to and b.ends_at > p_from;
$$;

-- Creazione prenotazione dal lato cliente, con controllo sovrapposizioni
create or replace function public.create_booking(p_token text, p_starts timestamptz, p_note text default '')
returns json language plpgsql security definer set search_path = public as $$
declare
  v_client clients%rowtype;
  v_slot int;
  v_ends timestamptz;
  v_id uuid;
begin
  select c.* into v_client from clients c where c.share_token = p_token;
  if not found then return json_build_object('error','Token non valido'); end if;

  select s.slot_minutes into v_slot from coach_settings s where s.id = v_client.coach_id;
  if v_slot is null then v_slot := 60; end if;
  v_ends := p_starts + make_interval(mins => v_slot);

  if p_starts < now() then return json_build_object('error','Lo slot è nel passato'); end if;

  if exists (select 1 from bookings b
             where b.coach_id = v_client.coach_id and b.status <> 'annullata'
               and b.starts_at < v_ends and b.ends_at > p_starts) then
    return json_build_object('error','Slot appena occupato: scegline un altro');
  end if;

  insert into bookings (coach_id, client_id, starts_at, ends_at, note)
  values (v_client.coach_id, v_client.id, p_starts, v_ends, left(coalesce(p_note,''), 500))
  returning id into v_id;

  return json_build_object('ok', true, 'id', v_id, 'starts_at', p_starts, 'ends_at', v_ends);
end;
$$;

grant execute on function public.get_client_by_token(text) to anon;
grant execute on function public.get_busy_slots(text, timestamptz, timestamptz) to anon;
grant execute on function public.create_booking(text, timestamptz, text) to anon;

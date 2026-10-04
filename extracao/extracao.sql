-- Extração de dados da revisão sistemática (troca de iBTK por intolerância)
-- Rodar uma vez no SQL Editor do MESMO projeto Supabase da Revisão iBTK (usa public.is_autor()).
-- Extração em duplicata cega garantida pelo banco:
--   cada extrator só lê a própria extração de um estudo;
--   a do outro só fica visível quando AS DUAS daquele estudo estão concluídas;
--   extração concluída não pode mais ser alterada (correções vão para o consenso);
--   toda gravação vai para o histórico.

-- ---------------------------------------------------------------- equipe
create table if not exists public.rs_equipe (
  email text primary key,
  papel text not null check (papel in ('extrator', 'adjudicador'))
);
alter table public.rs_equipe enable row level security;
drop policy if exists rs_equipe_ler on public.rs_equipe;
create policy rs_equipe_ler on public.rs_equipe for select to authenticated using (true);
drop policy if exists rs_equipe_autor on public.rs_equipe;
create policy rs_equipe_autor on public.rs_equipe for all to authenticated
  using (public.is_autor()) with check (public.is_autor());

create or replace function public.rs_papel()
returns text language sql stable security definer set search_path = public as $$
  select papel from public.rs_equipe where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''));
$$;

-- ---------------------------------------------------------------- estudos (catálogo; só o autor edita)
create table if not exists public.rs_estudos (
  id          text primary key check (id ~ '^[a-z0-9_]{3,40}$'),
  rotulo      text not null,
  referencia  text not null default '',
  doi         text not null default '',
  coorte      text not null default '',
  criado      timestamptz not null default now()
);
alter table public.rs_estudos enable row level security;
drop policy if exists rs_estudos_ler on public.rs_estudos;
create policy rs_estudos_ler on public.rs_estudos for select to authenticated
  using (public.rs_papel() is not null or public.is_autor());
drop policy if exists rs_estudos_autor on public.rs_estudos;
create policy rs_estudos_autor on public.rs_estudos for all to authenticated
  using (public.is_autor()) with check (public.is_autor());

-- ---------------------------------------------------------------- extrações (uma por extrator e estudo)
create table if not exists public.rs_extracoes (
  user_id     uuid not null references auth.users (id) on delete cascade,
  email       text,
  estudo_id   text not null references public.rs_estudos (id) on delete cascade,
  dados       jsonb not null default '{}'::jsonb,
  status      text not null default 'rascunho' check (status in ('rascunho', 'concluida')),
  concluida_em timestamptz,
  atualizado  timestamptz not null default now(),
  primary key (user_id, estudo_id)
);

-- Função que diz se o usuário atual já concluiu a extração de um estudo (security definer evita recursão de RLS)
create or replace function public.rs_concluiu(p_estudo text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.rs_extracoes
                 where estudo_id = p_estudo and user_id = auth.uid() and status = 'concluida');
$$;

create or replace function public.rs_carimbar()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.user_id := auth.uid();
  new.email := auth.jwt() ->> 'email';
  new.atualizado := now();
  if tg_op = 'UPDATE' and old.status = 'concluida' then
    raise exception 'Extração concluída não pode ser alterada; registre a correção no consenso.';
  end if;
  if new.status = 'concluida' and new.concluida_em is null then new.concluida_em := now(); end if;
  if new.status = 'rascunho' then new.concluida_em := null; end if;
  return new;
end $$;

drop trigger if exists t_rs_carimbar on public.rs_extracoes;
create trigger t_rs_carimbar before insert or update on public.rs_extracoes
  for each row execute function public.rs_carimbar();

alter table public.rs_extracoes enable row level security;
drop policy if exists rs_extr_ler on public.rs_extracoes;
create policy rs_extr_ler on public.rs_extracoes for select to authenticated using (
  user_id = auth.uid()
  or (status = 'concluida' and (public.rs_concluiu(estudo_id) or public.rs_papel() = 'adjudicador'))
);
drop policy if exists rs_extr_criar on public.rs_extracoes;
create policy rs_extr_criar on public.rs_extracoes for insert to authenticated
  with check (user_id = auth.uid() and public.rs_papel() = 'extrator');
drop policy if exists rs_extr_editar on public.rs_extracoes;
create policy rs_extr_editar on public.rs_extracoes for update to authenticated
  using (user_id = auth.uid() and status = 'rascunho') with check (user_id = auth.uid());

-- ---------------------------------------------------------------- consenso (um por estudo)
create table if not exists public.rs_consenso (
  estudo_id   text primary key references public.rs_estudos (id) on delete cascade,
  dados       jsonb not null default '{}'::jsonb,
  decisoes    jsonb not null default '{}'::jsonb,
  decidido_por text,
  atualizado  timestamptz not null default now()
);

create or replace function public.rs_ambas_concluidas(p_estudo text)
returns boolean language sql stable security definer set search_path = public as $$
  select count(*) >= 2 from public.rs_extracoes where estudo_id = p_estudo and status = 'concluida';
$$;

create or replace function public.rs_carimbar_consenso()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.decidido_por := auth.jwt() ->> 'email';
  new.atualizado := now();
  return new;
end $$;
drop trigger if exists t_rs_consenso on public.rs_consenso;
create trigger t_rs_consenso before insert or update on public.rs_consenso
  for each row execute function public.rs_carimbar_consenso();

alter table public.rs_consenso enable row level security;
drop policy if exists rs_cons_ler on public.rs_consenso;
create policy rs_cons_ler on public.rs_consenso for select to authenticated
  using (public.rs_papel() is not null or public.is_autor());
drop policy if exists rs_cons_escrever on public.rs_consenso;
create policy rs_cons_escrever on public.rs_consenso for insert to authenticated
  with check ((public.is_autor() or public.rs_papel() = 'adjudicador') and public.rs_ambas_concluidas(estudo_id));
drop policy if exists rs_cons_editar on public.rs_consenso;
create policy rs_cons_editar on public.rs_consenso for update to authenticated
  using (public.is_autor() or public.rs_papel() = 'adjudicador')
  with check (public.rs_ambas_concluidas(estudo_id));

-- ---------------------------------------------------------------- histórico (só acrescenta)
create table if not exists public.rs_historico (
  id            bigint generated always as identity primary key,
  tabela        text not null,
  estudo_id     text not null,
  email         text,
  status        text,
  dados         jsonb not null,
  registrado_em timestamptz not null default now()
);
alter table public.rs_historico enable row level security;
drop policy if exists rs_hist_ler on public.rs_historico;
create policy rs_hist_ler on public.rs_historico for select to authenticated using (public.is_autor());

create or replace function public.rs_registrar()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.rs_historico (tabela, estudo_id, email, status, dados)
  values (tg_table_name, new.estudo_id, auth.jwt() ->> 'email',
          coalesce(to_jsonb(new) ->> 'status', 'consenso'), new.dados);
  return new;
end $$;
drop trigger if exists t_rs_hist_extr on public.rs_extracoes;
create trigger t_rs_hist_extr after insert or update on public.rs_extracoes
  for each row execute function public.rs_registrar();
drop trigger if exists t_rs_hist_cons on public.rs_consenso;
create trigger t_rs_hist_cons after insert or update on public.rs_consenso
  for each row execute function public.rs_registrar();

revoke all on public.rs_equipe, public.rs_estudos, public.rs_extracoes, public.rs_consenso, public.rs_historico from anon;

-- ---------------------------------------------------------------- dados iniciais
insert into public.rs_equipe (email, papel) values ('thabranches@gmail.com', 'extrator')
  on conflict (email) do nothing;

insert into public.rs_estudos (id, rotulo, referencia, doi, coorte) values
 ('rogers2021', 'Rogers et al., 2021 (acalabrutinibe)', 'ROGERS, K. A. et al. Phase II study of acalabrutinib in ibrutinib-intolerant patients with relapsed/refractory chronic lymphocytic leukemia. Haematologica, v. 106, n. 9, p. 2364-2373, 2021.', '10.3324/haematol.2020.272500', 'ACE-CL-208'),
 ('shadman2025_215', 'Shadman et al., 2025 (zanubrutinibe, estudo 215)', 'SHADMAN, M. et al. Zanubrutinib is well tolerated and effective in patients with CLL/SLL intolerant of ibrutinib/acalabrutinib: updated results. Blood Advances, v. 9, n. 16, p. 4100-4110, 2025.', '10.1182/bloodadvances.2024015493', 'BGB-3111-215'),
 ('shah2025_bruin', 'Shah et al., 2025 (pirtobrutinibe, BRUIN)', 'SHAH, N. N. et al. Pirtobrutinib monotherapy in Bruton tyrosine kinase inhibitor-intolerant patients with B-cell malignancies: results of the phase I/II BRUIN trial. Haematologica, v. 110, n. 1, p. 92-102, 2025.', '10.3324/haematol.2024.285754', 'BRUIN (subgrupo intolerante)'),
 ('yan2026', 'Yan et al., 2026 (vida real, China)', 'YAN et al. Disease characteristics, treatment, and outcomes in Chinese chronic lymphocytic leukemia patients following BTK inhibitor discontinuation: a multicenter real-world study. Frontiers in Medicine, 2026.', '10.3389/fmed.2026.1739102', 'coorte multicêntrica')
on conflict (id) do nothing;

-- Para incluir o segundo extrator ou um adjudicador depois (troque o e-mail):
-- insert into public.rs_equipe (email, papel) values ('segundo@exemplo.com', 'extrator');
-- insert into public.rs_equipe (email, papel) values ('hemato@exemplo.com', 'adjudicador');

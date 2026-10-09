-- Revisão iBTK: banco de dados no Supabase
-- Rodar uma vez no SQL Editor do projeto (Supabase > SQL Editor > New query > colar > Run).
-- Revisão cega garantida pelo banco (Row Level Security):
--   cada revisor lê e grava só o próprio cadastro e as próprias decisões;
--   o autor (e-mail na tabela "autores") lê tudo, mas não grava em nome de ninguém;
--   toda gravação de decisão fica no histórico, que ninguém altera nem apaga pela página.

-- ---------------------------------------------------------------- autor
create table if not exists public.autores (
  email text primary key
);
alter table public.autores enable row level security;
-- Sem políticas: a tabela só é lida pela função abaixo e editada pelo painel do Supabase.

create or replace function public.is_autor()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.autores
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

-- ---------------------------------------------------------------- cadastro e vínculos
create table if not exists public.perfis (
  user_id        uuid primary key references auth.users (id) on delete cascade,
  email          text,
  nome           text not null check (length(trim(nome)) > 0),
  crm            text not null check (length(trim(crm)) > 0),
  instituicao    text not null default '',
  especialidade  text not null default '',
  vinculos       jsonb not null default '{}'::jsonb,
  sem_vinculos   boolean not null default false,
  tipo_vinculo   text not null default '',
  declaracao     boolean not null check (declaracao),
  criado         timestamptz not null default now(),
  atualizado     timestamptz not null default now()
);

-- ---------------------------------------------------------------- decisões (estado atual)
create table if not exists public.decisoes (
  user_id      uuid not null references auth.users (id) on delete cascade,
  item_id      text not null check (item_id ~ '^E[0-9]{2,4}$'),
  decisao      text check (decisao in ('concordo', 'ajuste', 'discordo', 'fora')),
  comentario   text not null default '',
  sugestao     text not null default '',
  versao_base  text not null,
  atualizado   timestamptz not null default now(),
  primary key (user_id, item_id)
);

-- ---------------------------------------------------------------- histórico (só acrescenta)
create table if not exists public.historico (
  id            bigint generated always as identity primary key,
  user_id       uuid not null,
  item_id       text not null,
  decisao       text,
  comentario    text not null,
  sugestao      text not null,
  versao_base   text not null,
  registrado_em timestamptz not null default now()
);

-- ---------------------------------------------------------------- revisores autorizados
-- Lista fechada, mantida só pelo autor (painel do Supabase). Só e-mails desta lista
-- conseguem criar cadastro e registrar decisões, mesmo que alguém consiga criar uma conta.
-- Nome e CRM vêm DESTA tabela (conferidos pelo autor), não do que a pessoa digita.
create table if not exists public.revisores_autorizados (
  email text primary key,
  nome  text not null,
  crm   text not null
);
alter table public.revisores_autorizados enable row level security;
-- Sem políticas: leitura só pelas funções abaixo; edição só pelo painel do Supabase.

create or replace function public.revisor_autorizado()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.revisores_autorizados
                 where lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));
$$;

create or replace function public.meu_cadastro_autorizado()
returns table (nome text, crm text) language sql stable security definer set search_path = public as $$
  select r.nome, r.crm from public.revisores_autorizados r
  where lower(r.email) = lower(coalesce(auth.jwt() ->> 'email', ''));
$$;

-- ---------------------------------------------------------------- carimbos do servidor
-- Dono, e-mail e horário vêm da sessão e do relógio do servidor, nunca do navegador.
create or replace function public.carimbar_perfil()
returns trigger language plpgsql security definer set search_path = public as $$
declare a record;
begin
  select r.nome, r.crm into a from public.revisores_autorizados r
   where lower(r.email) = lower(coalesce(auth.jwt() ->> 'email', ''));
  if not found then
    raise exception 'E-mail não autorizado como revisor' using errcode = '42501';
  end if;
  new.user_id    := auth.uid();
  new.email      := auth.jwt() ->> 'email';
  new.nome       := a.nome;   -- identidade conferida pelo autor, não digitada
  new.crm        := a.crm;
  new.atualizado := now();
  if tg_op = 'UPDATE' then new.criado := old.criado; end if;
  return new;
end $$;

create or replace function public.carimbar_decisao()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.user_id    := auth.uid();
  new.atualizado := now();
  return new;
end $$;

create or replace function public.registrar_historico()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.historico (user_id, item_id, decisao, comentario, sugestao, versao_base)
  values (new.user_id, new.item_id, new.decisao, new.comentario, new.sugestao, new.versao_base);
  return new;
end $$;

drop trigger if exists t_carimbar_perfil on public.perfis;
create trigger t_carimbar_perfil before insert or update on public.perfis
  for each row execute function public.carimbar_perfil();

drop trigger if exists t_carimbar_decisao on public.decisoes;
create trigger t_carimbar_decisao before insert or update on public.decisoes
  for each row execute function public.carimbar_decisao();

drop trigger if exists t_historico on public.decisoes;
create trigger t_historico after insert or update on public.decisoes
  for each row execute function public.registrar_historico();

-- ---------------------------------------------------------------- regras de acesso
alter table public.perfis    enable row level security;
alter table public.decisoes  enable row level security;
alter table public.historico enable row level security;

drop policy if exists perfis_ler on public.perfis;
create policy perfis_ler on public.perfis for select to authenticated
  using (user_id = auth.uid() or public.is_autor());
drop policy if exists perfis_criar on public.perfis;
create policy perfis_criar on public.perfis for insert to authenticated
  with check (user_id = auth.uid() and public.revisor_autorizado());
drop policy if exists perfis_editar on public.perfis;
create policy perfis_editar on public.perfis for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists decisoes_ler on public.decisoes;
create policy decisoes_ler on public.decisoes for select to authenticated
  using (user_id = auth.uid() or public.is_autor());
-- Só decide quem já fez o cadastro com a declaração de vínculos.
drop policy if exists decisoes_criar on public.decisoes;
create policy decisoes_criar on public.decisoes for insert to authenticated
  with check (user_id = auth.uid() and public.revisor_autorizado()
              and exists (select 1 from public.perfis p where p.user_id = auth.uid() and p.declaracao));
drop policy if exists decisoes_editar on public.decisoes;
create policy decisoes_editar on public.decisoes for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists historico_ler on public.historico;
create policy historico_ler on public.historico for select to authenticated
  using (user_id = auth.uid() or public.is_autor());
-- Sem políticas de escrita no histórico: só o gatilho grava nele.

revoke all on public.revisores_autorizados, public.autores, public.perfis, public.decisoes, public.historico from anon;

-- ---------------------------------------------------------------- depois de rodar
-- Cadastre o seu e-mail como autor (troque pelo seu):
-- insert into public.autores (email) values ('seu-email@exemplo.com');

-- Cadastre cada revisor (2 ou 3 hematologistas), com nome e CRM já conferidos no portal do CFM:
-- insert into public.revisores_autorizados (email, nome, crm) values
--   ('maurojorgejr@gmail.com', 'Mauro Jorge Freitas de Souza Junior', 'CRM 153876/UF');

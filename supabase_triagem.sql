-- Módulo do triador: conferência independente da triagem da base de evidência.
-- Rodar DEPOIS de supabase.sql e supabase_finalizacao.sql, uma vez, no SQL Editor (é seguro repetir).
--
-- Garantias, todas no banco (Row Level Security), não na página:
--   1. Só e-mails da lista fechada "triadores_autorizados" entram. Nome e CRF vêm da lista, conferidos pelo autor.
--   2. O triador lê os artigos da amostra e grava só as próprias decisões. NÃO existe caminho de leitura
--      para a decisão do autor: o gabarito fica em tabela que só o autor lê.
--   3. Toda gravação vai para um histórico que só o gatilho escreve.
--   4. A finalização usa o mesmo mecanismo da revisão (código próprio, hash SHA-256, trava, e-mail com data e hora).
-- Os dados da amostra e o gabarito NÃO ficam neste arquivo (o repositório é público): ver supabase_triagem_amostra.sql,
-- que o autor guarda fora do GitHub.

-- ---------------------------------------------------------------- lista fechada de triadores
create table if not exists public.triadores_autorizados (
  email text primary key,
  nome  text not null,
  crf   text not null
);
alter table public.triadores_autorizados enable row level security;
-- Sem políticas: leitura só pelas funções abaixo; edição só pelo painel do Supabase.

create or replace function public.triador_autorizado()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.triadores_autorizados
                 where lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));
$$;

create or replace function public.meu_cadastro_triador()
returns table (nome text, crf text) language sql stable security definer set search_path = public as $$
  select t.nome, t.crf from public.triadores_autorizados t
  where lower(t.email) = lower(coalesce(auth.jwt() ->> 'email', ''));
$$;

-- ---------------------------------------------------------------- declaração de vínculos
create table if not exists public.triagem_perfis (
  user_id      uuid primary key references auth.users (id) on delete cascade,
  email        text,
  nome         text not null,
  crf          text not null,
  vinculos     jsonb not null default '{}'::jsonb,
  sem_vinculos boolean not null default false,
  tipo_vinculo text not null default '',
  declaracao   boolean not null check (declaracao),
  criado       timestamptz not null default now(),
  atualizado   timestamptz not null default now()
);

-- ---------------------------------------------------------------- artigos da amostra (sem decisão do autor)
create table if not exists public.triagem_itens (
  n      int primary key,
  pmid   text not null default '',
  titulo text not null,
  link   text not null
);

-- ---------------------------------------------------------------- gabarito: SÓ o autor lê
create table if not exists public.triagem_gabarito (
  n       int primary key references public.triagem_itens (n) on delete cascade,
  decisao text not null check (decisao in ('Incluir', 'Excluir', 'Dúvida')),
  motivo  text not null default ''
);

-- ---------------------------------------------------------------- decisões do triador
create table if not exists public.triagem_decisoes (
  user_id    uuid not null references auth.users (id) on delete cascade,
  n          int  not null references public.triagem_itens (n) on delete cascade,
  decisao    text check (decisao in ('Incluir', 'Excluir', 'Dúvida')),
  motivo     text not null default '',
  atualizado timestamptz not null default now(),
  primary key (user_id, n)
);

create table if not exists public.triagem_historico (
  id            bigint generated always as identity primary key,
  user_id       uuid not null,
  n             int  not null,
  decisao       text,
  motivo        text not null,
  registrado_em timestamptz not null default now()
);

-- ---------------------------------------------------------------- carimbos do servidor
create or replace function public.carimbar_triagem_perfil()
returns trigger language plpgsql security definer set search_path = public as $$
declare a record;
begin
  select t.nome, t.crf into a from public.triadores_autorizados t
   where lower(t.email) = lower(coalesce(auth.jwt() ->> 'email', ''));
  if not found then
    raise exception 'E-mail não autorizado como triador' using errcode = '42501';
  end if;
  new.user_id    := auth.uid();
  new.email      := auth.jwt() ->> 'email';
  new.nome       := a.nome;   -- identidade conferida pelo autor, não digitada
  new.crf        := a.crf;
  new.atualizado := now();
  if tg_op = 'UPDATE' then new.criado := old.criado; end if;
  return new;
end $$;

create or replace function public.carimbar_triagem_decisao()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.user_id    := auth.uid();
  new.atualizado := now();
  return new;
end $$;

create or replace function public.registrar_triagem_historico()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.triagem_historico (user_id, n, decisao, motivo)
  values (new.user_id, new.n, new.decisao, new.motivo);
  return new;
end $$;

drop trigger if exists t_carimbar_triagem_perfil on public.triagem_perfis;
create trigger t_carimbar_triagem_perfil before insert or update on public.triagem_perfis
  for each row execute function public.carimbar_triagem_perfil();

drop trigger if exists t_carimbar_triagem_decisao on public.triagem_decisoes;
create trigger t_carimbar_triagem_decisao before insert or update on public.triagem_decisoes
  for each row execute function public.carimbar_triagem_decisao();

drop trigger if exists t_triagem_historico on public.triagem_decisoes;
create trigger t_triagem_historico after insert or update on public.triagem_decisoes
  for each row execute function public.registrar_triagem_historico();

-- Trava depois da finalização (reaproveita travar_se_finalizado, de supabase_finalizacao.sql).
drop trigger if exists t_a_travar_triagem_decisoes on public.triagem_decisoes;
create trigger t_a_travar_triagem_decisoes before insert or update or delete on public.triagem_decisoes
  for each row execute function public.travar_se_finalizado();
drop trigger if exists t_a_travar_triagem_perfis on public.triagem_perfis;
create trigger t_a_travar_triagem_perfis before insert or update or delete on public.triagem_perfis
  for each row execute function public.travar_se_finalizado();

-- ---------------------------------------------------------------- regras de acesso
alter table public.triagem_perfis    enable row level security;
alter table public.triagem_itens     enable row level security;
alter table public.triagem_gabarito  enable row level security;
alter table public.triagem_decisoes  enable row level security;
alter table public.triagem_historico enable row level security;

drop policy if exists triagem_perfis_ler on public.triagem_perfis;
create policy triagem_perfis_ler on public.triagem_perfis for select to authenticated
  using (user_id = auth.uid() or public.is_autor());
drop policy if exists triagem_perfis_criar on public.triagem_perfis;
create policy triagem_perfis_criar on public.triagem_perfis for insert to authenticated
  with check (user_id = auth.uid() and public.triador_autorizado());
drop policy if exists triagem_perfis_editar on public.triagem_perfis;
create policy triagem_perfis_editar on public.triagem_perfis for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists triagem_itens_ler on public.triagem_itens;
create policy triagem_itens_ler on public.triagem_itens for select to authenticated
  using (public.triador_autorizado() or public.is_autor());

-- Gabarito: leitura só do autor. Ninguém grava pela página (o autor carrega pelo SQL Editor).
drop policy if exists triagem_gabarito_ler on public.triagem_gabarito;
create policy triagem_gabarito_ler on public.triagem_gabarito for select to authenticated
  using (public.is_autor());

drop policy if exists triagem_decisoes_ler on public.triagem_decisoes;
create policy triagem_decisoes_ler on public.triagem_decisoes for select to authenticated
  using (user_id = auth.uid() or public.is_autor());
drop policy if exists triagem_decisoes_criar on public.triagem_decisoes;
create policy triagem_decisoes_criar on public.triagem_decisoes for insert to authenticated
  with check (user_id = auth.uid() and public.triador_autorizado()
              and exists (select 1 from public.triagem_perfis p where p.user_id = auth.uid() and p.declaracao));
drop policy if exists triagem_decisoes_editar on public.triagem_decisoes;
create policy triagem_decisoes_editar on public.triagem_decisoes for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists triagem_historico_ler on public.triagem_historico;
create policy triagem_historico_ler on public.triagem_historico for select to authenticated
  using (user_id = auth.uid() or public.is_autor());
-- Sem políticas de escrita no histórico: só o gatilho grava nele.

revoke all on public.triadores_autorizados, public.triagem_perfis, public.triagem_itens,
              public.triagem_gabarito, public.triagem_decisoes, public.triagem_historico from anon;

-- Permissões explícitas: a partir de 30/10/2026 o Supabase não concede mais GRANT automático em tabelas novas de public.
-- Só o que a página usa, e só para quem está autenticado; as políticas de RLS acima continuam valendo. Nada para anon.
grant select, insert, update on public.triagem_perfis    to authenticated;
grant select                 on public.triagem_itens     to authenticated;
grant select                 on public.triagem_gabarito  to authenticated;  -- a política limita ao autor
grant select, insert, update on public.triagem_decisoes  to authenticated;
grant select                 on public.triagem_historico to authenticated;
-- triadores_autorizados: sem GRANT, acessada só pelas funções.

-- ---------------------------------------------------------------- finalização (mesma tabela da revisão)
alter table public.finalizacoes add column if not exists tipo text not null default 'revisao';

create or replace function public.triagem_criar_codigo(p_codigo text)
returns void language plpgsql security definer set search_path = public as $$
declare p record;
begin
  if not public.triador_autorizado() then
    raise exception 'E-mail não autorizado como triador' using errcode = '42501';
  end if;
  select * into p from public.triagem_perfis where user_id = auth.uid() and declaracao;
  if not found then
    raise exception 'Faça a declaração de vínculos antes de criar o código' using errcode = '42501';
  end if;
  if p_codigo is null or length(p_codigo) < 8 then
    raise exception 'O código tem pelo menos 8 caracteres';
  end if;
  if exists (select 1 from public.finalizacoes where user_id = auth.uid()) then
    raise exception 'O código de finalização já foi criado';
  end if;
  insert into public.finalizacoes (user_id, email, nome, codigo_hash, tipo)
  values (auth.uid(), p.email, p.nome, extensions.crypt(p_codigo, extensions.gen_salt('bf')), 'triagem');
end $$;

create or replace function public.triagem_finalizar(p_codigo text, p_total_itens int default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare f record; r jsonb; h text; ts timestamptz := now();
begin
  if not public.triador_autorizado() then
    return jsonb_build_object('ok', false, 'motivo', 'nao_autorizado');
  end if;
  select * into f from public.finalizacoes where user_id = auth.uid() for update;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'sem_codigo'); end if;
  if f.finalizado_em is not null then
    return jsonb_build_object('ok', false, 'motivo', 'ja_finalizada', 'finalizado_em', f.finalizado_em);
  end if;
  if f.tentativas >= 5 then return jsonb_build_object('ok', false, 'motivo', 'bloqueado'); end if;
  if f.codigo_hash <> extensions.crypt(coalesce(p_codigo, ''), f.codigo_hash) then
    update public.finalizacoes set tentativas = tentativas + 1 where user_id = auth.uid();
    return jsonb_build_object('ok', false, 'motivo', 'codigo_incorreto', 'restantes', 4 - f.tentativas);
  end if;

  select jsonb_build_object(
           'avaliados', count(*) filter (where decisao is not null),
           'sem_decisao', case when p_total_itens is null then null
                               else greatest(p_total_itens - count(*) filter (where decisao is not null), 0) end,
           'incluir', count(*) filter (where decisao = 'Incluir'),
           'excluir', count(*) filter (where decisao = 'Excluir'),
           'duvida',  count(*) filter (where decisao = 'Dúvida')),
         encode(extensions.digest(coalesce(string_agg(
           n::text || ':' || coalesce(decisao, '') || ':' || motivo, '|' order by n), ''), 'sha256'), 'hex')
    into r, h
  from public.triagem_decisoes where user_id = auth.uid();

  update public.finalizacoes
     set finalizado_em = ts, resumo = r, hash_decisoes = h
   where user_id = auth.uid();
  return jsonb_build_object('ok', true, 'finalizado_em', ts, 'resumo', r, 'hash_decisoes', h);
end $$;

grant execute on function public.triagem_criar_codigo(text)     to authenticated;
grant execute on function public.triagem_finalizar(text, int)   to authenticated;
grant execute on function public.meu_cadastro_triador()          to authenticated;
revoke execute on function public.triagem_criar_codigo(text), public.triagem_finalizar(text, int),
                           public.meu_cadastro_triador() from anon;

-- ---------------------------------------------------------------- depois de rodar
-- 1) Cadastre o triador (nome e CRF conferidos por você no portal do CRF-SP):
-- insert into public.triadores_autorizados (email, nome, crf) values
--   ('triador@exemplo.com', 'Nome Completo', 'CRF-SP 00000');
-- 2) Crie o usuário em Authentication > Users (e-mail + senha provisória + Auto Confirm User).
-- 3) Rode o supabase_triagem_amostra.sql (guardado fora do GitHub) para carregar os 33 artigos e o gabarito.
-- 4) A função triagem_finalizar guarda hash; o e-mail de finalização sai pelo mesmo webhook da revisão.
-- Perdeu o código e AINDA NÃO finalizou? delete from public.finalizacoes where email = '...' and finalizado_em is null;

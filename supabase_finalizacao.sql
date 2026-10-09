-- Finalização da revisão: código próprio do revisor, definitivo e rastreável.
-- Rodar DEPOIS do supabase.sql, uma vez, no SQL Editor (é seguro repetir).
--
-- O que garante:
--   1. O revisor cria um código de finalização, separado da senha de login. O banco guarda só o hash.
--   2. Finalizar exige esse código. Depois disso, as decisões do revisor ficam TRAVADAS:
--      nem ele, nem o autor, nem a página conseguem inserir, editar ou apagar.
--   3. Na finalização o servidor grava data/hora e um hash SHA-256 das decisões (impressão digital).
--   4. A gravação da finalização dispara os e-mails (ver README, "E-mails de finalização").
--
-- Limite honesto: quem tem acesso de superusuário ao projeto Supabase (o dono do projeto) pode,
-- tecnicamente, desligar um gatilho. O que sustenta a rastreabilidade contra isso é o conjunto:
-- hash das decisões + e-mail com data e hora enviado ao revisor, que o autor não controla.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.finalizacoes (
  user_id          uuid primary key references auth.users (id) on delete cascade,
  email            text not null,
  nome             text not null,
  codigo_hash      text not null,
  tentativas       int  not null default 0,
  criado_em        timestamptz not null default now(),
  finalizado_em    timestamptz,
  resumo           jsonb,
  hash_decisoes    text,
  email_enviado_em timestamptz
);
alter table public.finalizacoes enable row level security;
-- Sem políticas: ninguém lê nem grava direto. Tudo passa pelas funções abaixo.
revoke all on public.finalizacoes from anon, authenticated;

-- ------------------------------------------------ o revisor consulta o próprio estado
create or replace function public.minha_finalizacao()
returns table (tem_codigo boolean, finalizado_em timestamptz, resumo jsonb, hash_decisoes text)
language sql stable security definer set search_path = public as $$
  select true, f.finalizado_em, f.resumo, f.hash_decisoes
  from public.finalizacoes f where f.user_id = auth.uid()
  union all
  select false, null, null, null
  where not exists (select 1 from public.finalizacoes f where f.user_id = auth.uid());
$$;

-- ------------------------------------------------ criar o código (uma única vez)
create or replace function public.criar_codigo_finalizacao(p_codigo text)
returns void language plpgsql security definer set search_path = public as $$
declare p record;
begin
  if not public.revisor_autorizado() then
    raise exception 'E-mail não autorizado como revisor' using errcode = '42501';
  end if;
  select * into p from public.perfis where user_id = auth.uid() and declaracao;
  if not found then
    raise exception 'Faça o cadastro e a declaração de vínculos antes de criar o código' using errcode = '42501';
  end if;
  if p_codigo is null or length(p_codigo) < 8 then
    raise exception 'O código tem pelo menos 8 caracteres';
  end if;
  if exists (select 1 from public.finalizacoes where user_id = auth.uid()) then
    raise exception 'O código de finalização já foi criado';
  end if;
  insert into public.finalizacoes (user_id, email, nome, codigo_hash)
  values (auth.uid(), p.email, p.nome, extensions.crypt(p_codigo, extensions.gen_salt('bf')));
end $$;

-- ------------------------------------------------ finalizar (definitivo)
create or replace function public.finalizar_revisao(p_codigo text, p_total_itens int default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare f record; r jsonb; h text; ts timestamptz := now();
begin
  if not public.revisor_autorizado() then
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
           'concordo', count(*) filter (where decisao = 'concordo'),
           'ajuste',   count(*) filter (where decisao = 'ajuste'),
           'discordo', count(*) filter (where decisao = 'discordo'),
           'fora',     count(*) filter (where decisao = 'fora')),
         encode(extensions.digest(coalesce(string_agg(
           item_id || ':' || coalesce(decisao, '') || ':' || comentario || ':' || sugestao || ':' || versao_base,
           '|' order by item_id), ''), 'sha256'), 'hex')
    into r, h
  from public.decisoes where user_id = auth.uid();

  update public.finalizacoes
     set finalizado_em = ts, resumo = r, hash_decisoes = h
   where user_id = auth.uid();
  return jsonb_build_object('ok', true, 'finalizado_em', ts, 'resumo', r, 'hash_decisoes', h);
end $$;

grant execute on function public.minha_finalizacao()                 to authenticated;
grant execute on function public.criar_codigo_finalizacao(text)      to authenticated;
grant execute on function public.finalizar_revisao(text, int)        to authenticated;
revoke execute on function public.minha_finalizacao(), public.criar_codigo_finalizacao(text),
                           public.finalizar_revisao(text, int) from anon;

-- ------------------------------------------------ trava: depois de finalizar, nada muda
create or replace function public.travar_se_finalizado()
returns trigger language plpgsql security definer set search_path = public as $$
declare uid uuid := coalesce(auth.uid(), old.user_id, new.user_id);  -- sessão do revisor manda; sem sessão (painel), vale a linha
begin
  if exists (select 1 from public.finalizacoes where user_id = uid and finalizado_em is not null) then
    raise exception 'Revisão finalizada: as decisões deste revisor estão travadas' using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;

drop trigger if exists t_a_travar_decisoes on public.decisoes;
create trigger t_a_travar_decisoes before insert or update or delete on public.decisoes
  for each row execute function public.travar_se_finalizado();

drop trigger if exists t_a_travar_perfis on public.perfis;
create trigger t_a_travar_perfis before insert or update or delete on public.perfis
  for each row execute function public.travar_se_finalizado();

-- A própria finalização não pode ser desfeita nem reescrita (só o carimbo do envio do e-mail muda).
create or replace function public.proteger_finalizacao()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    if old.finalizado_em is not null then
      raise exception 'Finalização é definitiva e não pode ser apagada' using errcode = '42501';
    end if;
    return old;
  end if;
  if old.finalizado_em is not null and (
       new.user_id is distinct from old.user_id or new.email is distinct from old.email
    or new.nome is distinct from old.nome or new.codigo_hash is distinct from old.codigo_hash
    or new.tentativas is distinct from old.tentativas or new.criado_em is distinct from old.criado_em
    or new.finalizado_em is distinct from old.finalizado_em or new.resumo is distinct from old.resumo
    or new.hash_decisoes is distinct from old.hash_decisoes) then
    raise exception 'Finalização é definitiva e não pode ser alterada' using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists t_proteger_finalizacao on public.finalizacoes;
create trigger t_proteger_finalizacao before update or delete on public.finalizacoes
  for each row execute function public.proteger_finalizacao();

-- ------------------------------------------------ ajuda do autor
-- Revisor perdeu o código e AINDA NÃO finalizou? Apague só a linha dele e ele cria outro:
--   delete from public.finalizacoes where email = 'revisor@exemplo.com' and finalizado_em is null;
-- Revisor bloqueado por 5 tentativas erradas? Zere as tentativas:
--   update public.finalizacoes set tentativas = 0 where email = 'revisor@exemplo.com' and finalizado_em is null;

-- Manutenção: função que o agendamento do GitHub chama para manter o projeto ativo.
-- Cole no Supabase > SQL Editor > Run (pode ser repetido).
-- A cada chamada, grava na tabela de controle public.heartbeat (uma única linha: hora do último ping e contador).
-- Motivo da escrita: só consultar o banco não bastou; o projeto pausou mesmo com o ping verde.
-- A tabela não tem política de acesso: ninguém a lê pela API; só a função (security definer) a atualiza.
create table if not exists public.heartbeat (
  id int primary key check (id = 1),
  ultimo_ping timestamptz not null default now(),
  total bigint not null default 0
);
alter table public.heartbeat enable row level security;
revoke all on public.heartbeat from anon, authenticated;

create or replace function public.ping()
returns timestamptz
language sql
volatile
security definer
set search_path = ''
as $$
  insert into public.heartbeat as h (id, ultimo_ping, total)
  values (1, now(), 1)
  on conflict (id) do update
    set ultimo_ping = now(), total = h.total + 1
  returning h.ultimo_ping;
$$;

revoke all on function public.ping() from public;
grant execute on function public.ping() to anon, authenticated;

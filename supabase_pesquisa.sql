-- Revisão iBTK: pesquisa curta de usabilidade e conteúdo, aberta ao clicar em "Sair"
-- Rodar DEPOIS do supabase.sql, no SQL Editor do Supabase. Pode ser rodado mais de uma vez.
-- Quem responde só grava; só o autor lê (painel e exportação em CSV). Não há edição nem exclusão pela página.

create table if not exists public.pesquisas (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users (id) on delete cascade,
  email       text,
  respostas   jsonb not null check (jsonb_typeof(respostas) = 'object' and length(respostas::text) < 4000),
  comentario  text not null default '' check (length(comentario) <= 2000),
  versao_base text not null,
  criado      timestamptz not null default now()
);

-- Dono, e-mail e horário vêm da sessão e do relógio do servidor, nunca do navegador.
create or replace function public.carimbar_pesquisa()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.user_id := auth.uid();
  new.email   := auth.jwt() ->> 'email';
  new.criado  := now();
  return new;
end $$;

drop trigger if exists t_carimbar_pesquisa on public.pesquisas;
create trigger t_carimbar_pesquisa before insert on public.pesquisas
  for each row execute function public.carimbar_pesquisa();

alter table public.pesquisas enable row level security;

drop policy if exists pesquisas_ler on public.pesquisas;
create policy pesquisas_ler on public.pesquisas for select to authenticated
  using (public.is_autor());

drop policy if exists pesquisas_criar on public.pesquisas;
create policy pesquisas_criar on public.pesquisas for insert to authenticated
  with check (user_id = auth.uid());

revoke all on public.pesquisas from anon;
revoke update, delete on public.pesquisas from authenticated;

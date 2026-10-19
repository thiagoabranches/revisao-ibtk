-- Aviso de primeiro acesso: o autor recebe um e-mail quando um revisor ou triador autorizado entra pela primeira vez.
-- Rodar uma vez no SQL Editor (é seguro repetir). Depois, criar o Database Webhook (ver README, "Aviso de acesso").
--
-- Como funciona: o login atualiza auth.users.last_sign_in_at; um gatilho grava UMA linha por pessoa em
-- public.acessos_primeiro; o Database Webhook (INSERT nessa tabela) chama a Edge Function avisar-acesso, que envia o e-mail.
-- O gatilho nunca derruba o login: qualquer erro nele é engolido.

create table if not exists public.acessos_primeiro (
  user_id          uuid primary key references auth.users (id) on delete cascade,
  email            text not null,
  papel            text not null,            -- 'revisor' ou 'triador'
  primeiro_acesso  timestamptz not null default now()
);
alter table public.acessos_primeiro enable row level security;
revoke all on public.acessos_primeiro from anon, authenticated;   -- sem políticas: só o autor, pelo painel

create or replace function public.registrar_primeiro_acesso()
returns trigger language plpgsql security definer set search_path = public as $$
declare papel text;
begin
  if new.last_sign_in_at is null or new.last_sign_in_at is not distinct from old.last_sign_in_at then
    return new;
  end if;
  select case
           when exists (select 1 from public.revisores_autorizados r where lower(r.email) = lower(new.email)) then 'revisor'
           when exists (select 1 from public.triadores_autorizados t where lower(t.email) = lower(new.email)) then 'triador'
         end into papel;
  if papel is not null then
    insert into public.acessos_primeiro (user_id, email, papel) values (new.id, new.email, papel)
    on conflict (user_id) do nothing;
  end if;
  return new;
exception when others then
  return new;   -- aviso é acessório: nunca impedir o login
end $$;

drop trigger if exists t_primeiro_acesso on auth.users;
create trigger t_primeiro_acesso after update of last_sign_in_at on auth.users
  for each row execute function public.registrar_primeiro_acesso();

-- Opcional: quem JÁ entrou antes de rodar este arquivo não deve gerar aviso retroativo? Então registre-os assim
-- (sem isso, o próximo login deles dispara um aviso, o que também serve de confirmação):
-- insert into public.acessos_primeiro (user_id, email, papel, primeiro_acesso)
-- select u.id, u.email, 'revisor', u.last_sign_in_at from auth.users u
-- where u.last_sign_in_at is not null and u.email in ('email@exemplo.com') on conflict do nothing;

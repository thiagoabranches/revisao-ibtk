-- Revisão iBTK: conclusão da revisão com CRM + código individual de conclusão
-- Rodar DEPOIS do supabase.sql e do supabase_v2_lista_revisores.sql, no SQL Editor do Supabase. Pode ser rodado mais de uma vez.
-- Efeito: o revisor encerra a própria revisão informando o CRM e um código individual, diferente da senha de login.
-- Depois disso, ele não grava nem altera mais decisões; só o autor reabre. Erros repetidos bloqueiam a conclusão por 30 minutos.

create extension if not exists pgcrypto with schema extensions;

alter table public.revisores add column if not exists crm text;
alter table public.revisores add column if not exists codigo_hash text;
alter table public.revisores add column if not exists tentativas integer not null default 0;
alter table public.revisores add column if not exists bloqueado_ate timestamptz;
alter table public.revisores add column if not exists concluida_em timestamptz;

-- Revisor ativo = autorizado e com revisão ainda não concluída.
create or replace function public.is_revisor_ativo()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.revisores
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
      and crm_verificado and concluida_em is null
  );
$$;

drop policy if exists perfis_criar on public.perfis;
create policy perfis_criar on public.perfis for insert to authenticated
  with check (user_id = auth.uid() and public.is_revisor_ativo());
drop policy if exists perfis_editar on public.perfis;
create policy perfis_editar on public.perfis for update to authenticated
  using (user_id = auth.uid() and public.is_revisor_ativo()) with check (user_id = auth.uid() and public.is_revisor_ativo());
drop policy if exists decisoes_criar on public.decisoes;
create policy decisoes_criar on public.decisoes for insert to authenticated
  with check (user_id = auth.uid() and public.is_revisor_ativo()
              and exists (select 1 from public.perfis p where p.user_id = auth.uid() and p.declaracao));
drop policy if exists decisoes_editar on public.decisoes;
create policy decisoes_editar on public.decisoes for update to authenticated
  using (user_id = auth.uid() and public.is_revisor_ativo()) with check (user_id = auth.uid() and public.is_revisor_ativo());

-- Quando o revisor concluiu (null = em andamento).
create or replace function public.minha_conclusao()
returns timestamptz language sql stable security definer set search_path = public as $$
  select concluida_em from public.revisores
  where lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')) and crm_verificado;
$$;

-- Conclusão. Devolve um texto: ok | ja_concluida | bloqueado | invalido | nao_autorizado.
-- O mesmo "invalido" vale para CRM errado e código errado (não revela qual dos dois falhou).
create or replace function public.concluir_revisao(p_crm text, p_codigo text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare r public.revisores%rowtype; ok boolean;
begin
  select * into r from public.revisores
   where lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')) and crm_verificado for update;
  if not found then return 'nao_autorizado'; end if;
  if r.concluida_em is not null then return 'ja_concluida'; end if;
  if r.bloqueado_ate is not null and r.bloqueado_ate > now() then return 'bloqueado'; end if;
  if r.codigo_hash is null or r.crm is null then return 'nao_autorizado'; end if;
  ok := upper(regexp_replace(coalesce(p_crm,''), '[^0-9A-Za-z]', '', 'g'))
        = upper(regexp_replace(r.crm, '[^0-9A-Za-z]', '', 'g'))
        and r.codigo_hash = crypt(coalesce(p_codigo,''), r.codigo_hash);
  if not ok then
    update public.revisores
       set bloqueado_ate = case when tentativas + 1 >= 5 then now() + interval '30 minutes' else bloqueado_ate end,
           tentativas = case when tentativas + 1 >= 5 then 0 else tentativas + 1 end
     where email = r.email;
    return 'invalido';
  end if;
  update public.revisores set concluida_em = now(), tentativas = 0, bloqueado_ate = null where email = r.email;
  return 'ok';
end $$;

-- Situação de cada revisor, só para o autor (painel).
create or replace function public.situacao_revisores()
returns table (email text, concluida_em timestamptz) language sql stable security definer set search_path = public as $$
  select r.email, r.concluida_em from public.revisores r where public.is_autor();
$$;

-- Definição do CRM e do código (rodado pelo autor no SQL Editor; nenhum papel da API consegue chamar).
create or replace function public.definir_codigo_conclusao(p_email text, p_crm text, p_codigo text)
returns void language sql security definer set search_path = public, extensions as $$
  update public.revisores
     set crm = p_crm, codigo_hash = crypt(p_codigo, gen_salt('bf')), tentativas = 0, bloqueado_ate = null
   where lower(email) = lower(p_email);
$$;

revoke all on function public.definir_codigo_conclusao(text, text, text) from public, anon, authenticated;
revoke all on function public.concluir_revisao(text, text) from public, anon;
revoke all on function public.minha_conclusao() from public, anon;
revoke all on function public.situacao_revisores() from public, anon;
grant execute on function public.concluir_revisao(text, text) to authenticated;
grant execute on function public.minha_conclusao() to authenticated;
grant execute on function public.situacao_revisores() to authenticated;

-- Para cada revisor (depois de inseri-lo em public.revisores, conforme o v2):
--   select public.definir_codigo_conclusao('revisor@exemplo.com', '123456/SP', 'CODIGO-UNICO-DO-REVISOR');
-- Envie o código por um canal diferente do usado para a senha de login.
-- Para reabrir uma revisão concluída:  update public.revisores set concluida_em = null where email = 'revisor@exemplo.com';

-- Painel do autor: leitura das finalizações dos revisores (rodar depois de supabase_finalizacao.sql).
-- Idempotente. Só o autor consegue chamar; não expõe o código de finalização.
create or replace function public.autor_finalizacoes()
returns table (user_id uuid, email text, finalizado_em timestamptz, hash_decisoes text, resumo jsonb, email_enviado_em timestamptz)
language plpgsql stable security definer
set search_path = public
as $$
begin
  if not public.is_autor() then
    raise exception 'Somente o autor' using errcode = '42501';
  end if;
  return query
    select f.user_id, f.email, f.finalizado_em, f.hash_decisoes, f.resumo, f.email_enviado_em
    from public.finalizacoes f;
end;
$$;
revoke all on function public.autor_finalizacoes() from public, anon;
grant execute on function public.autor_finalizacoes() to authenticated;

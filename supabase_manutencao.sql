-- Manutenção: função mínima que o agendamento do GitHub chama para manter o projeto ativo.
-- Cole no Supabase > SQL Editor > Run. Não lê nem grava nenhuma tabela: só devolve a hora do banco.
create or replace function public.ping()
returns timestamptz
language sql
stable
as $$ select now(); $$;

revoke all on function public.ping() from public;
grant execute on function public.ping() to anon, authenticated;

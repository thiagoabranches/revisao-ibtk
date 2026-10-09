// Edge Function: envia os e-mails quando um revisor finaliza a revisão.
// Disparada por um Database Webhook em public.finalizacoes (evento UPDATE). Ver README.
// Segredos necessários (supabase secrets set ...):
//   RESEND_API_KEY, EMAIL_REMETENTE (ex.: "Revisão iBTK <revisao@seudominio.com.br>"),
//   AUTOR_EMAIL, WEBHOOK_SECRET
// SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já existem dentro da função.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const fmt = (iso: string) =>
  new Date(iso).toLocaleString("pt-BR", { timeZone: "America/Sao_Paulo", dateStyle: "full", timeStyle: "medium" }) +
  " (horário de Brasília) · " + new Date(iso).toISOString().replace("T", " ").slice(0, 19) + " UTC";

async function enviar(para: string, assunto: string, texto: string) {
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${Deno.env.get("RESEND_API_KEY")}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: Deno.env.get("EMAIL_REMETENTE"), to: [para], subject: assunto, text: texto }),
  });
  if (!r.ok) throw new Error(`Resend ${r.status}: ${await r.text()}`);
}

Deno.serve(async (req) => {
  if (req.headers.get("x-webhook-secret") !== Deno.env.get("WEBHOOK_SECRET")) return new Response("não autorizado", { status: 401 });
  const { record, old_record } = await req.json();
  // Só quando a finalização acabou de acontecer e os e-mails ainda não saíram.
  if (!record?.finalizado_em || old_record?.finalizado_em || record.email_enviado_em) return new Response("ignorado");

  const quando = fmt(record.finalizado_em);
  const hash = record.hash_decisoes;
  const rs = record.resumo ?? {};

  await enviar(
    record.email,
    "Revisão iBTK: sua finalização foi registrada",
    `Olá, ${record.nome}.\n\nObrigado pela sua colaboração na revisão da ferramenta de consulta sobre inibidores de BTK.\n\n` +
      `Sua revisão foi finalizada em:\n${quando}\n\n` +
      `Achados avaliados: ${rs.avaliados ?? "-"}` + (rs.sem_decisao != null ? ` · sem decisão: ${rs.sem_decisao}` : "") + `\n` +
      `Impressão digital (SHA-256) das suas decisões:\n${hash}\n\n` +
      `A finalização é definitiva: suas decisões foram travadas nesse momento e ninguém, nem o autor, pode alterá-las. ` +
      `Guarde este e-mail: a data e a hora dele comprovam que o registro foi feito por você, sem intervenção do autor.\n\n` +
      `Thiago Abranches`,
  );
  await enviar(
    Deno.env.get("AUTOR_EMAIL")!,
    "Revisão iBTK: um revisor finalizou",
    `${record.nome} finalizou a revisão em ${quando}.\n\nImpressão digital das decisões:\n${hash}`,
  );

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  await sb.from("finalizacoes").update({ email_enviado_em: new Date().toISOString() }).eq("user_id", record.user_id);
  return new Response("ok");
});

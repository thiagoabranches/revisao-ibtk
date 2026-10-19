// Edge Function: avisa o autor quando um revisor ou triador autorizado acessa a plataforma pela primeira vez.
// Disparada por um Database Webhook em public.acessos_primeiro (evento INSERT). Ver README, "Aviso de acesso".
// Usa os mesmos segredos de notificar-finalizacao: RESEND_API_KEY, EMAIL_REMETENTE, AUTOR_EMAIL, WEBHOOK_SECRET.

Deno.serve(async (req) => {
  if (req.headers.get("x-webhook-secret") !== Deno.env.get("WEBHOOK_SECRET")) return new Response("não autorizado", { status: 401 });
  const { record } = await req.json();
  if (!record?.email) return new Response("ignorado");
  const autor = Deno.env.get("AUTOR_EMAIL")!;
  if (String(record.email).toLowerCase() === autor.toLowerCase()) return new Response("ignorado (autor)");

  const quando = new Date(record.primeiro_acesso).toLocaleString("pt-BR", { timeZone: "America/Sao_Paulo", dateStyle: "full", timeStyle: "medium" });
  const papel = record.papel === "triador" ? "triador(a)" : "revisor(a)";
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${Deno.env.get("RESEND_API_KEY")}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from: Deno.env.get("EMAIL_REMETENTE"),
      to: [autor],
      subject: `Oneiros · um(a) ${papel} acessou a plataforma`,
      text: `Um(a) ${papel} autorizado(a) entrou pela primeira vez.\n\nE-mail: ${record.email}\nQuando: ${quando} (horário de Brasília)\n`,
    }),
  });
  if (!r.ok) return new Response(`Resend ${r.status}: ${await r.text()}`, { status: 500 });
  return new Response("ok");
});

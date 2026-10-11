// Auditoria das referências da base (revisao-ibtk / consulta-ibtk) contra o Crossref.
// Uso (PowerShell, dentro da pasta do projeto):  node auditar_referencias.js index.html
// Saída: auditoria_referencias.csv (abra no Excel) + resumo no terminal.
// Requer Node 18+ (usa fetch). Faz 1 consulta por segundo; leva cerca de 2 minutos.
const fs = require("fs");

const arq = process.argv[2] || "index.html";
const html = fs.readFileSync(arq, "utf8");
const i = html.indexOf("const D = ");
if (i < 0) { console.error("Não achei 'const D = ' em " + arq); process.exit(1); }
const j = html.indexOf("\n", i);
const D = JSON.parse(html.slice(i + 10, j).replace(/;\s*$/, ""));
const refs = Object.entries(D.refs);

const norm = s => (s || "").toString().normalize("NFD").replace(/[̀-ͯ]/g, "")
  .toLowerCase().replace(/<[^>]+>/g, " ").replace(/[^a-z0-9]+/g, " ").trim();
const sleep = ms => new Promise(r => setTimeout(r, ms));
const doiDe = u => { const m = (u || "").match(/10\.\d{4,9}\/[^\s?#]+/); return m ? m[0].replace(/[.,;]$/, "") : ""; };

// extrai campos da referência ABNT (NBR 6023) gravada na base
function lerAbnt(a) {
  const sobrenome = (a.match(/^([^,]+),/) || [])[1] || "";
  const ano = (a.match(/(\d{4})\.?\s*$/) || a.match(/(\d{4})/) || [])[1] || "";
  const vol = (a.match(/\bv\.\s*([\w-]+)/) || [])[1] || "";
  const num = (a.match(/\bn\.\s*([\w-]+)/) || [])[1] || "";
  const pag = (a.match(/\bp\.\s*([\w.-]+)/) || [])[1] || "";
  const art = (a.match(/\bart\.\s*([\w.-]+)/i) || [])[1] || "";
  // título: entre "et al. " (ou "autor. ") e a próxima ". " antes da revista
  const t = a.replace(/^.*?(?:et al\.|[A-Z]\.)\s+/, "");
  return { sobrenome, ano, vol, num, pag, art, texto: norm(a) };
}

function comparar(a, w) {
  const m = w.message;
  const titulo = (m.title && m.title[0]) || "";
  const rev = (m["container-title"] && m["container-title"][0]) || "";
  const revC = (m["short-container-title"] && m["short-container-title"][0]) || "";
  const anos = [m["published-print"], m["published-online"], m.issued]
    .filter(Boolean).map(d => d["date-parts"] && d["date-parts"][0] && d["date-parts"][0][0]).filter(Boolean);
  const au = (m.author || []);
  const primeiro = au[0] ? au[0].family || au[0].name || "" : "";
  const p = lerAbnt(a);
  const dif = [];
  if (titulo && !p.texto.includes(norm(titulo).slice(0, 45))) dif.push("título");
  if (primeiro && !p.texto.startsWith(norm(primeiro).slice(0, 6))) dif.push("1º autor");
  if (rev && !(p.texto.includes(norm(rev)) || (revC && p.texto.includes(norm(revC))))) dif.push("revista");
  if (p.ano && anos.length && !anos.map(String).includes(p.ano)) dif.push("ano (Crossref: " + [...new Set(anos)].join("/") + ")");
  if (p.vol && m.volume && String(m.volume) !== p.vol) dif.push("volume (Crossref: " + m.volume + ")");
  if (p.num && m.issue && String(m.issue) !== p.num) dif.push("número (Crossref: " + m.issue + ")");
  const pagC = (m.page || m["article-number"] || "").toString();
  if (pagC && (p.pag || p.art)) {
    const alvo = norm(p.pag || p.art).replace(/ /g, "");
    const cand = norm(pagC).replace(/ /g, "");
    if (!alvo.includes(cand) && !cand.includes(alvo)) dif.push("páginas (Crossref: " + pagC + ")");
  }
  // retratação / errata
  const sinais = [];
  const up = [].concat(m["update-to"] || [], m["updated-by"] || []);
  up.forEach(u => sinais.push((u.type || u.label || "atualização") + (u.DOI ? " " + u.DOI : "")));
  if (m.relation) Object.keys(m.relation).forEach(k => { if (/retract|correct|erratum/i.test(k)) sinais.push(k); });
  if (/^(retracted|retraction|correction|erratum)/i.test(titulo)) sinais.push("título indica " + titulo.split(":")[0]);
  const retr = sinais.some(s => /retract/i.test(s));
  return { titulo, rev, anos: [...new Set(anos)].join("/"), vol: m.volume || "", num: m.issue || "", pag: pagC, dif, sinais, retr };
}

const csvq = v => '"' + String(v == null ? "" : v).replace(/"/g, '""') + '"';
(async () => {
  const L = [["chave", "rotulo", "doi", "status", "divergencias", "retratacao_ou_errata", "titulo_crossref", "revista_crossref", "ano_crossref", "vol_num_pag_crossref", "referencia_na_base"].map(csvq).join(",")];
  const cont = { OK: 0, DIVERGENCIA: 0, NAO_ENCONTRADO: 0, SEM_DOI: 0, ERRO: 0, ALERTA: 0 };
  for (const [k, v] of refs) {
    const doi = doiDe(v.url);
    let st = "", dif = "", sin = "", t = "", r = "", a = "", vnp = "";
    if (!doi) { st = "SEM_DOI"; dif = "conferir manualmente (bula/norma/site): " + v.url; cont.SEM_DOI++; }
    else {
      try {
        const res = await fetch("https://api.crossref.org/works/" + encodeURIComponent(doi).replace(/%2F/g, "/"));
        if (res.status === 404) { st = "NAO_ENCONTRADO"; dif = "DOI não existe no Crossref"; cont.NAO_ENCONTRADO++; }
        else if (!res.ok) { st = "ERRO"; dif = "HTTP " + res.status; cont.ERRO++; }
        else {
          const x = comparar(v.abnt, await res.json());
          t = x.titulo; r = x.rev; a = x.anos; vnp = [x.vol && "v." + x.vol, x.num && "n." + x.num, x.pag && "p." + x.pag].filter(Boolean).join(" ");
          sin = x.sinais.join("; ");
          if (x.retr) { st = "RETRATADO"; cont.ALERTA++; }
          else if (x.dif.length) { st = "DIVERGENCIA"; dif = x.dif.join("; "); cont.DIVERGENCIA++; }
          else { st = "OK"; cont.OK++; }
          if (sin && !x.retr) dif += (dif ? " | " : "") + "há errata/atualização: " + sin;
        }
      } catch (e) { st = "ERRO"; dif = String(e.message || e); cont.ERRO++; }
      await sleep(1000);
    }
    console.log(st.padEnd(15), k.padEnd(28), dif);
    L.push([k, v.rot, doi, st, dif, sin, t, r, a, vnp, v.abnt].map(csvq).join(","));
  }
  fs.writeFileSync("auditoria_referencias.csv", "﻿" + L.join("\n"), "utf8");
  console.log("\nResumo:", cont, "\nArquivo: auditoria_referencias.csv");
})();

# Revisão iBTK

Página de revisão cega dos achados da ferramenta de apoio à decisão sobre intolerância aos inibidores de BTK.
Hospedada no GitHub Pages; cadastros e decisões dos revisores ficam no Supabase, **nunca neste repositório**.

| Arquivo | Conteúdo |
|---|---|
| `index.html` | A página, com os 148 achados da base de 03/10/2026 embutidos |
| `config.js` | Endereço e chave pública do Supabase (os dois únicos valores a preencher) |
| `supabase.sql` | Tabelas, regras de acesso (revisão cega) e histórico de alterações |

## Como funciona a revisão cega

- Cada revisor entra com e-mail e senha criados pelo autor. Não há cadastro aberto.
- Cada revisor lê e grava só o próprio cadastro e as próprias decisões. Isso é garantido pelo banco (Row Level Security), não pela página.
- O autor vê tudo, mas não grava em nome de ninguém.
- Só registra decisões quem preencheu a declaração de vínculos.
- Toda gravação vai para um histórico com data e hora do servidor, que não pode ser alterado nem apagado pela página.

## Implantação

### 1. Supabase

1. Crie uma conta em supabase.com e um projeto novo. Região sugerida: South America (São Paulo).
2. Em **SQL Editor > New query**, cole todo o `supabase.sql` e clique em **Run**.
3. Ainda no SQL Editor, cadastre seu e-mail como autor:
   `insert into public.autores (email) values ('seu-email@exemplo.com');`
4. Em **Authentication > Sign In / Providers**:
   - mantenha **Email** ativo;
   - desligue **Allow new users to sign up**. Assim, ninguém cria conta sozinho.
5. Em **Authentication > Users > Add user > Create new user**, crie um usuário para você e um para cada revisor:
   - informe e-mail e senha provisória (mínimo 8 caracteres);
   - marque **Auto Confirm User**.
6. Em **Project Settings > API**, copie a **Project URL** e a chave pública (**anon** ou **publishable**) para o `config.js`.
   - **Nunca** use a chave `service_role` / `secret`.

Os nomes dos menus do Supabase mudam de tempos em tempos. Se algum não bater, procure pelo equivalente.

### 2. GitHub Pages

1. Crie um repositório novo, por exemplo `revisao-ibtk`. Ele é separado do `consulta-ibtk`, que continua só com a Versão A.
2. Envie `index.html`, `config.js`, `supabase.sql` e este `README.md`.
3. Em **Settings > Pages**, escolha **Deploy from a branch**, branch `main`, pasta `/ (root)`.
4. Em um ou dois minutos a página fica em `https://thiagoabranches.github.io/revisao-ibtk/`.

### 3. Convite ao revisor

Envie ao revisor o link, o e-mail e a senha provisória, e peça que ele troque a senha no primeiro acesso (botão **Trocar senha**, no topo).
Se ele esquecer a senha, redefina pelo painel do Supabase (**Authentication > Users**).

## Painel do autor

Entre com o seu usuário: aparece a aba **Painel do autor**. Nela você tem:
- os revisores, com os vínculos declarados;
- as divergências por achado;
- **Exportar decisões (CSV)**, com o estado atual;
- **Exportar histórico (CSV)**, com todas as gravações datadas, útil para a rastreabilidade do dossiê técnico.

## Observações

- A chave pública no `config.js` é visível para qualquer pessoa, por desenho do Supabase. Quem protege os dados são as regras do `supabase.sql`.
- No plano gratuito, o Supabase pausa projetos sem uso por cerca de uma semana. Basta reativar no painel; os dados são mantidos.
- Para atualizar os achados (nova versão da base), gere um novo `index.html` e substitua no repositório. Cada decisão guarda a versão da base em que foi feita (`versao_base`).

## Lista de revisores e finalização

Rode, nesta ordem, no SQL Editor: `supabase.sql` e depois `supabase_finalizacao.sql` (ambos podem ser repetidos).

**Lista fechada.** Só e-mails da tabela `revisores_autorizados` conseguem criar cadastro e registrar decisões. Nome e CRM vêm dessa tabela, conferidos por você (por exemplo, no portal do CFM), e não do que a pessoa digita:

```sql
insert into public.revisores_autorizados (email, nome, crm) values
  ('revisor@exemplo.com', 'Nome Completo', 'CRM 000000/UF');
```

**Finalização.** No primeiro acesso, depois do cadastro, o revisor cria um **código de finalização**, separado da senha de login, com um aviso explicando que a finalização é definitiva. Quando termina de avaliar, usa "Finalizar revisão" e digita o código. Daí em diante:

- as decisões e o cadastro dele ficam travados no banco: nem ele, nem você, nem a página alteram;
- o servidor grava data e hora e um hash SHA-256 das decisões;
- o código só é guardado cifrado, e 5 erros bloqueiam a tentativa.

Revisor perdeu o código e ainda não finalizou: apague só a linha dele em `finalizacoes` (comando comentado no fim do `supabase_finalizacao.sql`) e ele cria outro.

Limite: o dono do projeto Supabase pode, tecnicamente, desligar um gatilho. A prova contra isso é o conjunto: hash das decisões, mais o e-mail com data e hora que o revisor recebe e que você não controla.

### E-mails de finalização

A gravação da finalização dispara dois e-mails: ao revisor (agradecimento, data e hora, hash) e a você (aviso curto). Passo a passo:

1. Crie uma conta no Resend (resend.com) e verifique um domínio seu. Sem domínio verificado, o Resend só envia ao e-mail do próprio dono da conta.
2. Instale a CLI do Supabase e publique a função:
   `supabase functions deploy notificar-finalizacao --no-verify-jwt`
3. Defina os segredos:
   `supabase secrets set RESEND_API_KEY=... EMAIL_REMETENTE="Revisão iBTK <revisao@seudominio.com.br>" AUTOR_EMAIL=seu@email WEBHOOK_SECRET=uma-frase-longa`
4. No painel, em Database > Webhooks > Create: tabela `finalizacoes`, evento **Update**, tipo **Supabase Edge Functions** (ou HTTP Request para a URL da função), com o cabeçalho `x-webhook-secret` igual ao `WEBHOOK_SECRET`.
5. Teste com um revisor de teste antes de convidar os reais.

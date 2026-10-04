# Extração da revisão sistemática

Ferramenta de extração em duplicata cega para a revisão sobre troca de iBTK por intolerância. Fica na pasta `extracao/` do mesmo repositório e usa o mesmo projeto Supabase e o mesmo `config.js` da Revisão iBTK.

Endereço: `https://thiagoabranches.github.io/revisao-ibtk/extracao/`

## Instalação (uma vez)

1. **Supabase:** em **SQL Editor > New query**, cole todo o `extracao.sql` e clique em **Run**. O resultado esperado é "Success".
2. **GitHub:** no repositório `revisao-ibtk`, clique em **Add file > Upload files**, arraste a **pasta** `extracao` inteira e clique em **Commit changes**.

## Equipe

- Você já entra como extrator.
- Para o segundo extrator:
  1. crie o usuário em **Authentication > Users**;
  2. na ferramenta, abra a aba **Estudos e equipe** e inclua o e-mail dele com o papel **extrator**.
- Um hematologista para desempate entra do mesmo jeito, com o papel **adjudicador**.

## Regras garantidas pelo banco

- Cada extrator vê só a própria ficha de um estudo.
- A ficha do outro só aparece quando as duas daquele estudo estão concluídas.
- Ficha concluída não pode mais ser alterada; correções entram no consenso.
- O consenso só pode ser salvo depois que as duas fichas estão concluídas.
- Toda gravação fica no histórico.

## Planilha

A aba **Exportar planilha** gera um `.xlsx` com o estado atual. As abas são:

| Aba | Conteúdo |
|---|---|
| Estudos | Catálogo de estudos |
| Extracoes | Uma linha por extrator e estudo |
| Extracoes_desfechos | Uma linha por categoria de evento extraída |
| Divergencias | Diferenças entre os dois extratores |
| Consenso | Dados finais por estudo |
| Consenso_desfechos | Entrada para a metanálise |
| Dicionario | Definição de cada campo |
| Historico | Todas as gravações (só para o autor) |

## Atenção ao PROSPERO

Até o registro do protocolo, use a ferramenta só para o **piloto** com os estudos-índice. A extração formal começa depois do registro.

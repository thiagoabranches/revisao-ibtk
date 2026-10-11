# Auditoria das referências

Confere cada referência da base (campo `refs` do `index.html`) contra o Crossref: título, primeiro autor, revista, ano, volume, número, páginas e sinais de retratação ou errata.

Na pasta raiz do projeto:

```
node ferramentas/auditar_referencias.js index.html
```

Gera `auditoria_referencias.csv` (abre no Excel). Requer Node 18 ou superior. Faz uma consulta por segundo (cerca de 2 minutos para 61 DOIs). As referências sem DOI (bulas, notícias regulatórias) aparecem como SEM_DOI e exigem conferência manual.
